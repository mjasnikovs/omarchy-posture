"""Three pose models behind one interface for the bake-off.

infer(rgb uint8 HxWx3, crop) -> np.ndarray (7, 3): x, y, score in frame pixels
for KP = nose, l_eye, r_eye, l_ear, r_ear, l_sh, r_sh.
crop = (cx, cy, w, h) in frame pixels, or None for the whole frame.
"""
import math

import numpy as np

KP = ["nose", "l_eye", "r_eye", "l_ear", "r_ear", "l_sh", "r_sh"]
COCO_IDX = [0, 1, 2, 3, 4, 5, 6]
BLAZE_IDX = [0, 2, 5, 7, 8, 11, 12]


def yuyv_to_rgb(buf, w, h):
    a = np.frombuffer(buf, np.uint8).reshape(h, w // 2, 4).astype(np.float32)
    y = np.empty((h, w), np.float32)
    y[:, 0::2] = a[:, :, 0]
    y[:, 1::2] = a[:, :, 2]
    u = np.repeat(a[:, :, 1], 2, axis=1) - 128
    v = np.repeat(a[:, :, 3], 2, axis=1) - 128
    rgb = np.stack([y + 1.402 * v, y - 0.344136 * u - 0.714136 * v, y + 1.772 * u], -1)
    return np.clip(rgb, 0, 255).astype(np.uint8)


def warp(img, M, ow, oh):
    """Bilinear sample: output pixel (u,v) <- img at M @ [u,v,1] (M maps out->src)."""
    h, w = img.shape[:2]
    us, vs = np.meshgrid(np.arange(ow, dtype=np.float32) + 0.5, np.arange(oh, dtype=np.float32) + 0.5)
    sx = M[0, 0] * us + M[0, 1] * vs + M[0, 2] - 0.5
    sy = M[1, 0] * us + M[1, 1] * vs + M[1, 2] - 0.5
    x0 = np.floor(sx).astype(np.int32)
    y0 = np.floor(sy).astype(np.int32)
    fx = (sx - x0)[..., None]
    fy = (sy - y0)[..., None]
    pad = np.zeros((h + 2, w + 2, img.shape[2]), np.float32)
    pad[1:-1, 1:-1] = img
    x0c = np.clip(x0 + 1, 0, w + 1)
    x1c = np.clip(x0 + 2, 0, w + 1)
    y0c = np.clip(y0 + 1, 0, h + 1)
    y1c = np.clip(y0 + 2, 0, h + 1)
    top = pad[y0c, x0c] * (1 - fx) + pad[y0c, x1c] * fx
    bot = pad[y1c, x0c] * (1 - fx) + pad[y1c, x1c] * fx
    return top * (1 - fy) + bot * fy


def crop_matrix(cx, cy, cw, ch, ow, oh, rot=0.0):
    """Out pixel -> source pixel for a (possibly rotated) box centred at cx, cy."""
    c, s = math.cos(rot), math.sin(rot)
    sx, sy = cw / ow, ch / oh
    return np.array([
        [c * sx, -s * sy, cx - c * sx * ow / 2 + s * sy * oh / 2],
        [s * sx, c * sy, cy - s * sx * ow / 2 - c * sy * oh / 2],
    ], np.float32)


def fit_aspect(crop, aspect, frame_w, frame_h):
    if crop is None:
        crop = (frame_w / 2, frame_h / 2, frame_w, frame_h)
    cx, cy, w, h = crop
    if w / h > aspect:
        h = w / aspect
    else:
        w = h * aspect
    return cx, cy, w, h


class RTMPose:
    name = "rtmpose-t"

    def __init__(self, path, session_factory):
        self.sess = session_factory(path)
        self.inp = self.sess.get_inputs()[0].name
        self.mean = np.array([123.675, 116.28, 103.53], np.float32)
        self.std = np.array([58.395, 57.12, 57.375], np.float32)

    def infer(self, rgb, crop):
        H, W = rgb.shape[:2]
        cx, cy, cw, ch = fit_aspect(crop, 192 / 256, W, H)
        M = crop_matrix(cx, cy, cw, ch, 192, 256)
        x = (warp(rgb, M, 192, 256) - self.mean) / self.std
        x = x.transpose(2, 0, 1)[None].astype(np.float32)
        sx, sy = self.sess.run(None, {self.inp: x})
        ix, iy = sx[0].argmax(-1), sy[0].argmax(-1)
        score = np.minimum(sx[0].max(-1), sy[0].max(-1))
        u, v = ix / 2.0, iy / 2.0
        px = M[0, 0] * u + M[0, 1] * v + M[0, 2]
        py = M[1, 0] * u + M[1, 1] * v + M[1, 2]
        return np.stack([px, py, score], -1)[COCO_IDX]


class MoveNet:
    def __init__(self, path, interp_factory, name):
        self.name = name
        self.it = interp_factory(path)
        self.it.allocate_tensors()
        d = self.it.get_input_details()[0]
        self.inp, self.dtype, self.size = d["index"], d["dtype"], int(d["shape"][1])
        self.out = self.it.get_output_details()[0]["index"]

    def infer(self, rgb, crop):
        H, W = rgb.shape[:2]
        n = self.size
        cx, cy, cw, ch = fit_aspect(crop, 1.0, W, H)
        M = crop_matrix(cx, cy, cw, ch, n, n)
        x = np.clip(warp(rgb, M, n, n), 0, 255)[None].astype(self.dtype)
        self.it.set_tensor(self.inp, x)
        self.it.invoke()
        k = self.it.get_tensor(self.out)[0, 0]  # 17 x (y, x, score), normalised
        u, v = k[:, 1] * n, k[:, 0] * n
        px = M[0, 0] * u + M[0, 1] * v + M[0, 2]
        py = M[1, 0] * u + M[1, 1] * v + M[1, 2]
        return np.stack([px, py, k[:, 2]], -1)[COCO_IDX]


def _blaze_anchors():
    anchors = []
    strides = [8, 16, 32, 32, 32]
    i = 0
    while i < len(strides):
        n = 0
        j = i
        while j < len(strides) and strides[j] == strides[i]:
            n += 2
            j += 1
        fm = math.ceil(224 / strides[i])
        for y in range(fm):
            for x in range(fm):
                for _ in range(n):
                    anchors.append(((x + 0.5) / fm, (y + 0.5) / fm))
        i = j
    return np.array(anchors, np.float32)


class BlazePose:
    """MediaPipe BlazePose lite: detector once, then landmark-driven ROI tracking."""

    name = "blazepose-lite"

    def __init__(self, det_path, lm_path, interp_factory):
        self.det = interp_factory(det_path)
        self.det.allocate_tensors()
        self.lm = interp_factory(lm_path)
        self.lm.allocate_tensors()
        self.anchors = _blaze_anchors()
        assert len(self.anchors) == 2254
        self.det_out = {tuple(d["shape"]): d["index"] for d in self.det.get_output_details()}
        self.lm_out = {d["shape"][-1]: d["index"] for d in self.lm.get_output_details() if len(d["shape"]) == 2}
        self.roi = None

    def _detect(self, rgb):
        H, W = rgb.shape[:2]
        side = max(W, H)
        M = crop_matrix(W / 2, H / 2, side, side, 224, 224)
        x = (warp(rgb, M, 224, 224) / 127.5 - 1.0)[None].astype(np.float32)
        self.det.set_tensor(self.det.get_input_details()[0]["index"], x)
        self.det.invoke()
        reg = self.det.get_tensor(self.det_out[(1, 2254, 12)])[0]
        cls = self.det.get_tensor(self.det_out[(1, 2254, 1)])[0, :, 0]
        best = int(np.argmax(cls))
        if 1 / (1 + math.exp(-cls[best])) < 0.5:
            return None
        a = self.anchors[best]
        kp = reg[best, 4:].reshape(4, 2) / 224 + a  # normalised in the square crop
        kp = kp * side + np.array([W / 2 - side / 2, H / 2 - side / 2])
        return kp[0], kp[1]

    def _roi(self, center, scale_pt):
        d = scale_pt - center
        size = 2 * math.hypot(*d) * 1.25
        rot = math.pi / 2 - math.atan2(-d[1], d[0])
        rot = rot - 2 * math.pi * math.floor((rot + math.pi) / (2 * math.pi))
        return center[0], center[1], size, rot

    def infer(self, rgb, crop):
        if self.roi is None:
            det = self._detect(rgb)
            if det is None:
                return np.zeros((7, 3), np.float32)
            self.roi = self._roi(*det)
        cx, cy, size, rot = self.roi
        M = crop_matrix(cx, cy, size, size, 256, 256, rot)
        x = (warp(rgb, M, 256, 256) / 255.0)[None].astype(np.float32)
        self.lm.set_tensor(self.lm.get_input_details()[0]["index"], x)
        self.lm.invoke()
        lm = self.lm.get_tensor(self.lm_out[195])[0].reshape(39, 5)
        flag = self.lm.get_tensor(self.lm_out[1])[0, 0]
        u, v = lm[:, 0], lm[:, 1]
        px = M[0, 0] * u + M[0, 1] * v + M[0, 2]
        py = M[1, 0] * u + M[1, 1] * v + M[1, 2]
        vis = 1 / (1 + np.exp(-lm[:, 3]))
        if flag < 0.5:
            self.roi = None
            return np.zeros((7, 3), np.float32)
        pts = np.stack([px, py], -1)
        self.roi = self._roi(pts[33], pts[34])
        return np.stack([px, py, vis], -1)[BLAZE_IDX]
