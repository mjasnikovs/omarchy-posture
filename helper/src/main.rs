// omarchy-posture-helper: a plain pose sensor for the Omarchy Posture plugin.
//
// Reads the webcam, runs RTMPose-t, prints one JSON line per frame on stdout.
// All posture logic lives in the plugin. Frames never leave memory.
//
// stdout:  {"ev":"status","state":"running|paused|no-camera|error","detail":"..."}
//          {"ev":"pose","t":<unix ms>,"w":640,"h":480,"kp":[[x,y,score] x7]}
//          kp order: nose, left eye, right eye, left ear, right ear, left shoulder, right shoulder.
// stdin:   pause | resume | fps <n> | device [path] | prefer [path] | quit
//          End of stdin exits, so the helper dies with the shell that started it.
mod camera;
mod pose;

use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, Write};
use std::ops::Not;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, TryRecvError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use camera::Camera;
use pose::{H, Keypoints, Pose, W};

const MODEL_FILE: &str = "rtmpose-t.onnx";
const DEFAULT_MODEL: &str = "/usr/share/omarchy-posture/rtmpose-t.onnx";
const DEFAULT_FPS: u32 = 5;
const RETRY: Duration = Duration::from_secs(5);

const USAGE: &str = "usage: omarchy-posture-helper [--model PATH] [--device PATH] [--prefer PATH] [--fps N] [--paused]
                             [--record FILE] [--replay FILE [--loop]]";

enum Cmd {
    Pause,
    Resume,
    Fps(u32),
    Device(String),
    Prefer(String),
    Quit,
}

struct Args {
    model: String,
    device: String,
    // The camera the slate was made on. In auto mode it is tried first, and
    // switched back to when it returns.
    prefer: String,
    fps: u32,
    paused: bool,
    record: Option<String>,
    replay: Option<String>,
    looped: bool,
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}\n{USAGE}");
            std::process::exit(2);
        }
    };
    // The lock keeps two plugin helpers off one camera. Replay uses no camera,
    // and --record is a manual tool, so neither takes it.
    let _lock = if args.replay.is_none() && args.record.is_none() {
        match lock() {
            Ok(l) => Some(l),
            Err(e) => {
                status("error", &format!("another helper is running ({e})"));
                std::process::exit(3);
            }
        }
    } else {
        None
    };
    let cmds = spawn_stdin();
    let mut out = Out::new(args.record.as_deref());
    if let Some(path) = &args.replay {
        replay(path, args.looped, args.fps, args.paused, &cmds, &mut out);
        return;
    }
    let mut pose = match Pose::load(&args.model) {
        Ok(p) => p,
        Err(e) => {
            status("error", &format!("cannot load model {}: {e}", args.model));
            // Exit so the plugin retries with backoff and picks up a model
            // installed later. Its status keeps showing this error meanwhile.
            std::process::exit(4);
        }
    };
    run(args, &mut pose, &cmds, &mut out);
}

fn run(mut args: Args, pose: &mut Pose, cmds: &Receiver<Cmd>, out: &mut Out) {
    let mut cam: Option<Camera> = None;
    let mut next_try = Instant::now();
    // When the next frame is due. Frames arriving well before it (a camera
    // that ignored the rate request) are skipped. A schedule, not "time since
    // the last frame", so a late wakeup does not cost the next frame.
    let mut next_due = Instant::now();
    // Set after a failed inference, so the next good frame reports "running" again.
    let mut errored = false;
    // The device actually open, for status lines.
    let mut using = String::new();
    // A camera that opened but sent no frames. Tried last next time, so an
    // auto-picked dead node cannot hide a working camera behind it.
    let mut avoid: Option<String> = None;
    // Frames from the camera now open. A camera that failed after sending
    // frames is not dead, and must keep its place (the slate was made on it).
    let mut frames_seen: u64 = 0;
    let mut next_prefer_check = Instant::now();
    if args.paused {
        status("paused", "");
    }
    loop {
        // Commands first. While paused, block on them instead of spinning.
        loop {
            let cmd = if args.paused {
                match cmds.recv_timeout(Duration::from_secs(1)) {
                    Ok(c) => c,
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            } else {
                match cmds.try_recv() {
                    Ok(c) => c,
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => return,
                }
            };
            match cmd {
                Cmd::Quit => return,
                Cmd::Pause => {
                    cam = None;
                    args.paused = true;
                    status("paused", "");
                }
                Cmd::Resume if args.paused => {
                    args.paused = false;
                    next_try = Instant::now();
                }
                Cmd::Resume => {}
                Cmd::Fps(n) => {
                    args.fps = n.clamp(1, 30);
                    cam = None;
                    next_try = Instant::now();
                }
                Cmd::Device(d) => {
                    args.device = d;
                    cam = None;
                    next_try = Instant::now();
                }
                Cmd::Prefer(p) => {
                    args.prefer = p;
                    next_prefer_check = Instant::now();
                }
            }
        }

        if cam.is_none() {
            if Instant::now() < next_try {
                std::thread::sleep(Duration::from_millis(200));
                continue;
            }
            match open_camera(&args.device, &args.prefer, args.fps, avoid.as_deref()) {
                Ok((c, path)) => {
                    cam = Some(c);
                    errored = false;
                    frames_seen = 0;
                    using = camera::name(&path);
                    status("running", &using);
                }
                Err(e) => {
                    status("no-camera", &e);
                    next_try = Instant::now() + RETRY;
                    continue;
                }
            }
        }

        // Running on a fallback camera: every 10 s, open the preferred one
        // alongside. If it works, switch. A failed try leaves the current one be.
        if args.device.is_empty()
            && !args.prefer.is_empty()
            && Instant::now() >= next_prefer_check
            && camera::same(&using, &args.prefer).not()
        {
            next_prefer_check = Instant::now() + Duration::from_secs(10);
            if let Ok(c) = Camera::open(&args.prefer, args.fps) {
                cam = Some(c);
                frames_seen = 0;
                using = camera::name(&args.prefer);
                status("running", &using);
            }
        }

        let Some(c) = cam.as_mut() else { continue };
        let frame = match c.frame() {
            Ok(f) => {
                frames_seen += 1;
                f
            }
            Err(e) => {
                cam = None;
                if frames_seen == 0 {
                    avoid = Some(using.clone());
                    // A preferred camera that opens but streams nothing must not
                    // pull the helper off a working fallback every 10 s.
                    if camera::same(&using, &args.prefer) {
                        next_prefer_check = Instant::now() + Duration::from_secs(300);
                    }
                }
                status("no-camera", &format!("{using}: {e}"));
                next_try = Instant::now() + RETRY;
                continue;
            }
        };
        let interval = Duration::from_millis(1000 / args.fps as u64);
        let now = Instant::now();
        if now + interval / 4 < next_due {
            continue;
        }
        next_due += interval;
        if next_due < now {
            // Fell behind (slow frame, camera stall): start the schedule over.
            next_due = now + interval;
        }
        match pose.run(frame) {
            Ok(kp) => {
                avoid = None;
                if errored {
                    errored = false;
                    status("running", &using);
                }
                out.pose(&kp)
            }
            Err(e) => {
                errored = true;
                status("error", &format!("inference failed: {e}"));
            }
        }
    }
}

// Feeds recorded pose lines back at the requested rate, for driving the plugin without a camera.
fn replay(path: &str, looped: bool, fps: u32, start_paused: bool, cmds: &Receiver<Cmd>, out: &mut Out) {
    let lines: Vec<Keypoints> = match std::fs::read_to_string(path) {
        Ok(s) => s.lines().filter_map(parse_kp).collect(),
        Err(e) => {
            status("error", &format!("cannot read {path}: {e}"));
            return;
        }
    };
    if lines.is_empty() {
        status("error", &format!("no pose lines in {path}"));
        return;
    }
    let mut paused = start_paused;
    if paused {
        status("paused", "");
    } else {
        status("running", &format!("replay {path}"));
    }
    let interval = Duration::from_millis(1000 / fps.max(1) as u64);
    let mut i = 0;
    let mut finished = false;
    // Frames go out on a schedule; commands arriving between them do not
    // shorten the spacing.
    let mut next_due = Instant::now() + interval;
    loop {
        let wait = next_due.saturating_duration_since(Instant::now());
        match cmds.recv_timeout(wait) {
            Ok(Cmd::Quit) | Err(RecvTimeoutError::Disconnected) => return,
            Ok(Cmd::Pause) => {
                paused = true;
                status("paused", "");
                continue;
            }
            Ok(Cmd::Resume) if paused && !finished => {
                paused = false;
                status("running", &format!("replay {path}"));
                next_due = Instant::now() + interval;
                continue;
            }
            Ok(_) => continue,
            Err(RecvTimeoutError::Timeout) => {}
        }
        next_due += interval;
        if paused || finished {
            continue;
        }
        if i == lines.len() {
            if !looped {
                status("no-camera", "replay finished");
                finished = true;
                continue;
            }
            i = 0;
        }
        out.pose(&lines[i]);
        i += 1;
    }
}

// Reads the kp array from a pose line this helper wrote.
fn parse_kp(line: &str) -> Option<Keypoints> {
    let start = line.find("\"kp\":")? + 5;
    let body = &line[start..];
    let end = body.find("]]")? + 2;
    let nums: Vec<f32> = body[..end]
        .split(|c: char| c == '[' || c == ']' || c == ',')
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().parse().ok())
        .collect::<Option<_>>()?;
    if nums.len() != pose::KEYPOINTS * 3 {
        return None;
    }
    let mut kp = [[0.0; 3]; pose::KEYPOINTS];
    for (k, p) in kp.iter_mut().enumerate() {
        *p = [nums[k * 3], nums[k * 3 + 1], nums[k * 3 + 2]];
    }
    Some(kp)
}

struct Out {
    record: Option<File>,
}

impl Out {
    fn new(record: Option<&str>) -> Out {
        let record = record.and_then(|p| match OpenOptions::new().create(true).append(true).open(p) {
            Ok(f) => Some(f),
            Err(e) => {
                status("error", &format!("cannot record to {p}: {e}"));
                None
            }
        });
        Out { record }
    }

    fn pose(&mut self, kp: &Keypoints) {
        let pts: Vec<String> = kp.iter().map(|p| format!("[{:.1},{:.1},{:.3}]", p[0], p[1], p[2])).collect();
        let line = format!(
            "{{\"ev\":\"pose\",\"t\":{},\"w\":{W},\"h\":{H},\"kp\":[{}]}}",
            now_ms(),
            pts.join(",")
        );
        emit(&line);
        if let Some(f) = self.record.as_mut() {
            let _ = writeln!(f, "{line}");
        }
    }
}

fn status(state: &str, detail: &str) {
    emit(&format!("{{\"ev\":\"status\",\"state\":\"{state}\",\"detail\":\"{}\"}}", escape(detail)));
}

fn emit(line: &str) {
    let mut o = io::stdout().lock();
    // A closed stdout means the shell is gone. Exit quietly.
    if writeln!(o, "{line}").and_then(|_| o.flush()).is_err() {
        std::process::exit(0);
    }
}

fn escape(s: &str) -> String {
    let mut r = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => r.push_str("\\\""),
            '\\' => r.push_str("\\\\"),
            c if (c as u32) < 0x20 => r.push_str(&format!("\\u{:04x}", c as u32)),
            c => r.push(c),
        }
    }
    r
}

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

fn spawn_stdin() -> Receiver<Cmd> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            let mut parts = line.trim().splitn(2, ' ');
            let cmd = match (parts.next().unwrap_or(""), parts.next().map(str::trim)) {
                ("pause", _) => Cmd::Pause,
                ("resume", _) => Cmd::Resume,
                ("quit", _) => Cmd::Quit,
                ("fps", Some(n)) => match n.parse() {
                    Ok(n) => Cmd::Fps(n),
                    Err(_) => continue,
                },
                // "device" alone goes back to the first camera that works.
                ("device", d) => Cmd::Device(d.unwrap_or("").to_string()),
                ("prefer", d) => Cmd::Prefer(d.unwrap_or("").to_string()),
                _ => continue,
            };
            if tx.send(cmd).is_err() {
                break;
            }
        }
        // Dropping tx tells the main loop that stdin closed.
    });
    rx
}

// One helper per user. The lock is released when the process exits.
fn lock() -> io::Result<File> {
    let dir = state_dir();
    std::fs::create_dir_all(&dir)?;
    let f = OpenOptions::new().create(true).truncate(false).write(true).open(dir.join("helper.lock"))?;
    f.try_lock().map_err(|e| io::Error::other(e.to_string()))?;
    Ok(f)
}

fn state_dir() -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state"));
    base.join("omarchy/posture")
}

// First that exists: $OMARCHY_POSTURE_MODEL, the packaged path, next to the
// binary, then ~/.local/share/omarchy-posture. Falls back to the packaged path
// so the error names where the model should be.
fn default_model() -> String {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(p) = std::env::var_os("OMARCHY_POSTURE_MODEL") {
        candidates.push(PathBuf::from(p));
    }
    candidates.push(PathBuf::from(DEFAULT_MODEL));
    if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(PathBuf::from)) {
        candidates.push(dir.join(MODEL_FILE));
    }
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share"));
    candidates.push(data.join("omarchy-posture").join(MODEL_FILE));
    candidates
        .into_iter()
        .find(|p| p.is_file())
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| DEFAULT_MODEL.into())
}

// An empty device means "first camera that works". Errors name the first
// candidate, which is the one the user most likely means.
// An empty device means "first camera that works", the preferred one first.
// Errors name the first candidate, which is the one the user most likely means.
fn open_camera(device: &str, prefer: &str, fps: u32, avoid: Option<&str>) -> Result<(Camera, String), String> {
    let mut list = if device.is_empty() { camera::candidates() } else { vec![device.to_string()] };
    if device.is_empty() && !prefer.is_empty() {
        list.retain(|p| !camera::same(p, prefer));
        list.insert(0, prefer.to_string());
    }
    if let Some(bad) = avoid {
        if let Some(i) = list.iter().position(|p| camera::same(p, bad)) {
            let p = list.remove(i);
            list.push(p);
        }
    }
    let mut first_err = None;
    for path in list {
        match Camera::open(&path, fps) {
            Ok(c) => return Ok((c, path)),
            Err(e) => {
                first_err.get_or_insert(format!("{path}: {e}"));
            }
        }
    }
    Err(first_err.unwrap_or_else(|| "no camera found".into()))
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        model: String::new(),
        device: String::new(),
        prefer: String::new(),
        fps: DEFAULT_FPS,
        paused: false,
        record: None,
        replay: None,
        looped: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        let mut val = || it.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--model" => a.model = val()?,
            "--device" => a.device = val()?,
            "--prefer" => a.prefer = val()?,
            "--fps" => a.fps = val()?.parse().map_err(|_| "--fps needs a number".to_string())?,
            "--record" => a.record = Some(val()?),
            "--replay" => a.replay = Some(val()?),
            "--paused" => a.paused = true,
            "--loop" => a.looped = true,
            "-h" | "--help" => return Err(String::new()),
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    a.fps = a.fps.clamp(1, 30);
    if a.model.is_empty() {
        a.model = default_model();
    }
    Ok(a)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_own_pose_lines() {
        let line = r#"{"ev":"pose","t":1,"w":640,"h":480,"kp":[[1.0,2.0,0.9],[3,4,0.8],[5,6,0.7],[7,8,0.6],[9,10,0.5],[11,12,0.4],[13,14,0.3]]}"#;
        let kp = parse_kp(line).expect("pose line");
        assert_eq!(kp[0], [1.0, 2.0, 0.9]);
        assert_eq!(kp[6], [13.0, 14.0, 0.3]);
    }

    #[test]
    fn parses_fixture_lines_with_spaces() {
        let line = r#"{"t": 1, "label": "good", "kp": [[1, 2, 0.9], [3, 4, 0.8], [5, 6, 0.7], [7, 8, 0.6], [9, 10, 0.5], [11, 12, 0.4], [13, 14, 0.3]]}"#;
        assert!(parse_kp(line).is_some());
    }

    #[test]
    fn rejects_status_and_short_lines() {
        assert!(parse_kp(r#"{"ev":"status","state":"running","detail":""}"#).is_none());
        assert!(parse_kp(r#"{"kp":[[1,2,3]]}"#).is_none());
    }

    #[test]
    fn escapes_json_strings() {
        assert_eq!(escape("a\"b\\c\n"), "a\\\"b\\\\c\\u000a");
    }
}
