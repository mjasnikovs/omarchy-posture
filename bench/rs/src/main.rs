// Bake-off helper: camera (or replay file) -> RTMPose-t -> JSON lines.
// Usage: posebench MODEL (--dev PATH --frames N | --replay FILE) [--crop cx,cy,w,h]
use std::io::{Read, Write};
use std::time::Instant;

const W: usize = 640;
const H: usize = 480;
const IW: usize = 192;
const IH: usize = 256;
const COCO: [usize; 7] = [0, 1, 2, 3, 4, 5, 6];
const MEAN: [f32; 3] = [123.675, 116.28, 103.53];
const STD: [f32; 3] = [58.395, 57.12, 57.375];

struct Crop {
    m: [f32; 6],
}

impl Crop {
    fn new(c: Option<[f32; 4]>) -> Crop {
        let [cx, cy, mut w, mut h] = c.unwrap_or([W as f32 / 2.0, H as f32 / 2.0, W as f32, H as f32]);
        let aspect = IW as f32 / IH as f32;
        if w / h > aspect { h = w / aspect } else { w = h * aspect }
        let (sx, sy) = (w / IW as f32, h / IH as f32);
        Crop { m: [sx, 0.0, cx - sx * IW as f32 / 2.0, 0.0, sy, cy - sy * IH as f32 / 2.0] }
    }
    fn map(&self, u: f32, v: f32) -> (f32, f32) {
        let m = &self.m;
        (m[0] * u + m[1] * v + m[2], m[3] * u + m[4] * v + m[5])
    }
}

fn rgb_at(f: &[u8], x: i32, y: i32) -> [f32; 3] {
    if x < 0 || y < 0 || x >= W as i32 || y >= H as i32 {
        return [0.0; 3];
    }
    let (x, y) = (x as usize, y as usize);
    let base = y * W * 2 + (x & !1) * 2;
    let yy = f[base + (x & 1) * 2] as f32;
    let u = f[base + 1] as f32 - 128.0;
    let v = f[base + 3] as f32 - 128.0;
    [
        (yy + 1.402 * v).clamp(0.0, 255.0),
        (yy - 0.344136 * u - 0.714136 * v).clamp(0.0, 255.0),
        (yy + 1.772 * u).clamp(0.0, 255.0),
    ]
}

fn preprocess(frame: &[u8], crop: &Crop, out: &mut [f32]) {
    for v in 0..IH {
        for u in 0..IW {
            let (sx, sy) = crop.map(u as f32 + 0.5, v as f32 + 0.5);
            let (sx, sy) = (sx - 0.5, sy - 0.5);
            let (x0, y0) = (sx.floor(), sy.floor());
            let (fx, fy) = (sx - x0, sy - y0);
            let (x0, y0) = (x0 as i32, y0 as i32);
            let a = rgb_at(frame, x0, y0);
            let b = rgb_at(frame, x0 + 1, y0);
            let c = rgb_at(frame, x0, y0 + 1);
            let d = rgb_at(frame, x0 + 1, y0 + 1);
            for ch in 0..3 {
                let top = a[ch] * (1.0 - fx) + b[ch] * fx;
                let bot = c[ch] * (1.0 - fx) + d[ch] * fx;
                let px = top * (1.0 - fy) + bot * fy;
                out[ch * IH * IW + v * IW + u] = (px - MEAN[ch]) / STD[ch];
            }
        }
    }
}

fn decode(sx: &[f32], sy: &[f32], crop: &Crop) -> Vec<[f32; 3]> {
    let (nx, ny) = (IW * 2, IH * 2);
    COCO.iter()
        .map(|&k| {
            let rx = &sx[k * nx..(k + 1) * nx];
            let ry = &sy[k * ny..(k + 1) * ny];
            let (ix, mx) = argmax(rx);
            let (iy, my) = argmax(ry);
            let (px, py) = crop.map(ix as f32 / 2.0, iy as f32 / 2.0);
            [px, py, mx.min(my)]
        })
        .collect()
}

fn argmax(v: &[f32]) -> (usize, f32) {
    v.iter().enumerate().fold((0, f32::MIN), |b, (i, &x)| if x > b.1 { (i, x) } else { b })
}

#[cfg(feature = "rt-ort")]
mod rt {
    use ort::session::Session;
    use ort::value::Tensor;
    pub struct Model(Session);
    impl Model {
        pub fn load(p: &str) -> Model {
            let s = Session::builder().unwrap().with_intra_threads(1).unwrap().with_inter_threads(1).unwrap()
                .commit_from_file(p).unwrap();
            Model(s)
        }
        pub fn run(&mut self, x: &[f32]) -> (Vec<f32>, Vec<f32>) {
            let t = Tensor::from_array(([1usize, 3, super::IH, super::IW], x.to_vec().into_boxed_slice())).unwrap();
            let out = self.0.run(ort::inputs!["input" => t]).unwrap();
            let (_, a) = out["simcc_x"].try_extract_tensor::<f32>().unwrap();
            let (_, b) = out["simcc_y"].try_extract_tensor::<f32>().unwrap();
            (a.to_vec(), b.to_vec())
        }
    }
}

#[cfg(feature = "rt-tract")]
mod rt {
    use tract_onnx::prelude::*;
    pub struct Model(std::sync::Arc<TypedRunnableModel>);
    impl Model {
        pub fn load(p: &str) -> Model {
            let m = tract_onnx::onnx()
                .with_ignore_output_shapes(true)
                .with_ignore_value_info(true)
                .model_for_path(p).unwrap()
                .with_input_fact(0, f32::fact([1, 3, super::IH, super::IW]).into()).unwrap()
                .into_optimized().unwrap()
                .into_runnable().unwrap();
            Model(m)
        }
        pub fn run(&mut self, x: &[f32]) -> (Vec<f32>, Vec<f32>) {
            let t: Tensor = tract_ndarray::Array4::from_shape_vec((1, 3, super::IH, super::IW), x.to_vec()).unwrap().into();
            let r = self.0.run(tvec!(t.into())).unwrap();
            (r[0].to_plain_array_view::<f32>().unwrap().as_slice().unwrap().to_vec(), r[1].to_plain_array_view::<f32>().unwrap().as_slice().unwrap().to_vec())
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let get = |k: &str| args.iter().position(|a| a == k).map(|i| args[i + 1].clone());
    let crop = Crop::new(get("--crop").map(|c| {
        let v: Vec<f32> = c.split(',').map(|x| x.parse().unwrap()).collect();
        [v[0], v[1], v[2], v[3]]
    }));
    let mut model = rt::Model::load(&args[1]);
    let mut input = vec![0f32; 3 * IH * IW];
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let mut step = |frame: &[u8], out: &mut std::io::StdoutLock| {
        let t0 = Instant::now();
        preprocess(frame, &crop, &mut input);
        let t1 = Instant::now();
        let (sx, sy) = model.run(&input);
        let kp = decode(&sx, &sy, &crop);
        let t2 = Instant::now();
        let pts: Vec<String> = kp.iter().map(|p| format!("[{:.2},{:.2},{:.3}]", p[0], p[1], p[2])).collect();
        writeln!(out, "{{\"pre_ms\":{:.2},\"inf_ms\":{:.2},\"kp\":[{}]}}",
            (t1 - t0).as_secs_f64() * 1e3, (t2 - t1).as_secs_f64() * 1e3, pts.join(",")).unwrap();
    };
    if let Some(path) = get("--replay") {
        let mut f = std::fs::File::open(path).unwrap();
        let mut buf = vec![0u8; W * H * 2];
        while f.read_exact(&mut buf).is_ok() {
            step(&buf, &mut out);
        }
        return;
    }
    use v4l::io::traits::CaptureStream;
    use v4l::video::Capture;
    let dev = v4l::Device::with_path(get("--dev").unwrap()).unwrap();
    let mut fmt = dev.format().unwrap();
    fmt.width = W as u32;
    fmt.height = H as u32;
    fmt.fourcc = v4l::FourCC::new(b"YUYV");
    dev.set_format(&fmt).unwrap();
    let mut p = dev.params().unwrap();
    p.interval = v4l::Fraction::new(1, 5);
    dev.set_params(&p).unwrap();
    let frames: usize = get("--frames").unwrap().parse().unwrap();
    let mut stream = v4l::io::mmap::Stream::with_buffers(&dev, v4l::buffer::Type::VideoCapture, 2).unwrap();
    for _ in 0..frames {
        let (buf, _) = stream.next().unwrap();
        let frame = buf.to_vec();
        step(&frame, &mut out);
    }
}
