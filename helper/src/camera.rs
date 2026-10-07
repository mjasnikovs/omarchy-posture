// The webcam, opened only while frames are wanted. Dropping a Camera closes
// the device, which turns the LED off and frees it for other apps.
use std::io;
use std::path::PathBuf;
use std::time::Duration;
use v4l::buffer::Type;
use v4l::io::mmap::Stream;
use v4l::io::traits::CaptureStream;
use v4l::video::Capture;

use crate::pose::{H, W};

// A camera that stops sending frames (some do after resume) must not block
// the main loop, or pause and end of stdin would go unread.
const FRAME_TIMEOUT: Duration = Duration::from_secs(3);

pub struct Camera {
    // The stream keeps its own handle to the device; the field order drops it first.
    stream: Stream<'static>,
    _dev: v4l::Device,
    // Bytes per row. Drivers may pad rows past W * 2.
    stride: usize,
    packed: Vec<u8>,
}

impl Camera {
    pub fn open(path: &str, fps: u32) -> io::Result<Camera> {
        let dev = v4l::Device::with_path(path)?;
        let mut fmt = dev.format()?;
        fmt.width = W as u32;
        fmt.height = H as u32;
        fmt.fourcc = v4l::FourCC::new(b"YUYV");
        // Ask for packed rows. The driver may still pad them; frame() copes.
        fmt.stride = (W * 2) as u32;
        let got = dev.set_format(&fmt)?;
        if got.width as usize != W || got.height as usize != H || got.fourcc != fmt.fourcc {
            return Err(io::Error::other(format!(
                "camera gave {}x{} {}, need {W}x{H} YUYV",
                got.width, got.height, got.fourcc
            )));
        }
        let stride = (got.stride as usize).max(W * 2);
        let mut params = dev.params()?;
        params.interval = v4l::Fraction::new(1, fps.max(1));
        // Not every camera accepts every rate. The main loop paces itself anyway.
        let _ = dev.set_params(&params);
        let mut stream = Stream::with_buffers(&dev, Type::VideoCapture, 2)?;
        stream.set_timeout(FRAME_TIMEOUT);
        Ok(Camera { stream, _dev: dev, stride, packed: Vec::new() })
    }

    pub fn frame(&mut self) -> io::Result<&[u8]> {
        let (buf, meta) = self.stream.next()?;
        let used = (meta.bytesused as usize).min(buf.len());
        let row = W * 2;
        if used < self.stride * (H - 1) + row {
            return Err(io::Error::other(format!("short frame: {used} bytes")));
        }
        if self.stride == row {
            return Ok(&buf[..row * H]);
        }
        self.packed.resize(row * H, 0);
        for y in 0..H {
            self.packed[y * row..(y + 1) * row].copy_from_slice(&buf[y * self.stride..y * self.stride + row]);
        }
        Ok(&self.packed)
    }
}

/// Capture nodes to try when no device is set: every by-id "index0" node
/// (one per USB camera), then the plain /dev/video* nodes. A laptop's IR
/// camera can sort first; it fails the YUYV check and the next one is tried.
pub fn candidates() -> Vec<String> {
    let mut by_id: Vec<PathBuf> = std::fs::read_dir("/dev/v4l/by-id")
        .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    by_id.retain(|p| p.to_string_lossy().ends_with("-video-index0"));
    by_id.sort();
    let mut plain: Vec<PathBuf> = std::fs::read_dir("/dev")
        .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    plain.retain(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("video")));
    plain.sort();
    // A by-id name and its /dev/videoN target are the same device: keep the first name.
    let mut seen = std::collections::HashSet::new();
    let mut out: Vec<String> = by_id
        .iter()
        .chain(plain.iter())
        .filter(|p| seen.insert(std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())))
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    if out.is_empty() {
        out.push("/dev/video0".into());
    }
    out
}

/// The stable name for a camera node: its /dev/v4l/by-id link when one
/// points at it, so /dev/video0 and its by-id alias report the same name.
pub fn name(path: &str) -> String {
    let Ok(target) = std::fs::canonicalize(path) else { return path.to_string() };
    let mut links: Vec<PathBuf> = std::fs::read_dir("/dev/v4l/by-id")
        .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    links.sort();
    links
        .into_iter()
        .find(|l| std::fs::canonicalize(l).is_ok_and(|t| t == target))
        .map(|l| l.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string())
}

/// Whether two paths name the same device node.
pub fn same(a: &str, b: &str) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => a == b,
    }
}
