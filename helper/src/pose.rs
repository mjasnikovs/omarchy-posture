// RTMPose-t on the whole frame. YUYV in, seven upper-body keypoints out.
//
// The bake-off (bench/RESULTS.md) found the whole frame as good as a crop for
// one seated person, so there is no person detector and no crop.
use tract_onnx::prelude::*;
use tract_onnx::tract_core::internal::{bail, format_err};

pub const W: usize = 640;
pub const H: usize = 480;
const IW: usize = 192;
const IH: usize = 256;
// COCO order: nose, left eye, right eye, left ear, right ear, left shoulder, right shoulder.
pub const KEYPOINTS: usize = 7;
const MEAN: [f32; 3] = [123.675, 116.28, 103.53];
const STD: [f32; 3] = [58.395, 57.12, 57.375];

pub type Keypoints = [[f32; 3]; KEYPOINTS];

pub struct Pose {
    plan: std::sync::Arc<TypedRunnableModel>,
    // Model pixel -> frame pixel: x = sx * u + ox, y = sy * v + oy.
    sx: f32,
    sy: f32,
    ox: f32,
    oy: f32,
}

impl Pose {
    pub fn load(path: &str) -> TractResult<Pose> {
        let plan = tract_onnx::onnx()
            // The exported model carries a symbolic batch in its value info that
            // tract cannot unify with batch 1.
            .with_ignore_output_shapes(true)
            .with_ignore_value_info(true)
            .model_for_path(path)?
            .with_input_fact(0, f32::fact([1, 3, IH, IW]).into())?
            .into_optimized()?
            .into_runnable()?;
        // Fit the frame into the model's 3:4 box, keeping the aspect ratio.
        let (mut bw, mut bh) = (W as f32, H as f32);
        let aspect = IW as f32 / IH as f32;
        if bw / bh > aspect {
            bh = bw / aspect
        } else {
            bw = bh * aspect
        }
        let (sx, sy) = (bw / IW as f32, bh / IH as f32);
        Ok(Pose {
            plan,
            sx,
            sy,
            ox: W as f32 / 2.0 - sx * IW as f32 / 2.0,
            oy: H as f32 / 2.0 - sy * IH as f32 / 2.0,
        })
    }

    pub fn run(&mut self, yuyv: &[u8]) -> TractResult<Keypoints> {
        // Preprocess straight into the input tensor: no second buffer, no copy.
        let mut input = Tensor::zero::<f32>(&[1, 3, IH, IW])?;
        {
            let mut view = input.to_plain_array_view_mut::<f32>()?;
            let buf = view.as_slice_mut().ok_or_else(|| format_err!("input tensor is not contiguous"))?;
            self.preprocess(yuyv, buf);
        }
        let out = self.plan.run(tvec!(input.into()))?;
        if out.len() < 2 {
            bail!("model gave {} outputs, need simcc_x and simcc_y", out.len());
        }
        let simcc_x = out[0].to_plain_array_view::<f32>()?;
        let simcc_y = out[1].to_plain_array_view::<f32>()?;
        let (nx, ny) = (IW * 2, IH * 2);
        let xs = simcc_x.as_slice().ok_or_else(|| format_err!("simcc_x is not contiguous"))?;
        let ys = simcc_y.as_slice().ok_or_else(|| format_err!("simcc_y is not contiguous"))?;
        // A different model behind OMARCHY_POSTURE_MODEL must fail here, not panic.
        if xs.len() < KEYPOINTS * nx || ys.len() < KEYPOINTS * ny {
            bail!("model output too small: {} and {} values", xs.len(), ys.len());
        }
        let mut kp = [[0.0; 3]; KEYPOINTS];
        for (k, p) in kp.iter_mut().enumerate() {
            let (ix, mx) = argmax(&xs[k * nx..(k + 1) * nx]);
            let (iy, my) = argmax(&ys[k * ny..(k + 1) * ny]);
            // SimCC bins are half a model pixel wide.
            *p = [
                self.sx * ix as f32 / 2.0 + self.ox,
                self.sy * iy as f32 / 2.0 + self.oy,
                mx.min(my),
            ];
        }
        Ok(kp)
    }

    fn preprocess(&self, f: &[u8], input: &mut [f32]) {
        for v in 0..IH {
            for u in 0..IW {
                let sx = self.sx * (u as f32 + 0.5) + self.ox - 0.5;
                let sy = self.sy * (v as f32 + 0.5) + self.oy - 0.5;
                let (x0, y0) = (sx.floor(), sy.floor());
                let (fx, fy) = (sx - x0, sy - y0);
                let (x0, y0) = (x0 as i32, y0 as i32);
                let a = rgb_at(f, x0, y0);
                let b = rgb_at(f, x0 + 1, y0);
                let c = rgb_at(f, x0, y0 + 1);
                let d = rgb_at(f, x0 + 1, y0 + 1);
                for ch in 0..3 {
                    let top = a[ch] * (1.0 - fx) + b[ch] * fx;
                    let bot = c[ch] * (1.0 - fx) + d[ch] * fx;
                    let px = top * (1.0 - fy) + bot * fy;
                    input[ch * IH * IW + v * IW + u] = (px - MEAN[ch]) / STD[ch];
                }
            }
        }
    }
}

// Outside the frame reads as black, matching the padding the model was tested with.
fn rgb_at(f: &[u8], x: i32, y: i32) -> [f32; 3] {
    if x < 0 || y < 0 || x >= W as i32 || y >= H as i32 {
        return [0.0; 3];
    }
    let (x, y) = (x as usize, y as usize);
    let base = y * W * 2 + (x & !1) * 2;
    let luma = f[base + (x & 1) * 2] as f32;
    let u = f[base + 1] as f32 - 128.0;
    let v = f[base + 3] as f32 - 128.0;
    [
        (luma + 1.402 * v).clamp(0.0, 255.0),
        (luma - 0.344136 * u - 0.714136 * v).clamp(0.0, 255.0),
        (luma + 1.772 * u).clamp(0.0, 255.0),
    ]
}

fn argmax(v: &[f32]) -> (usize, f32) {
    v.iter()
        .enumerate()
        .fold((0, f32::MIN), |best, (i, &x)| if x > best.1 { (i, x) } else { best })
}
