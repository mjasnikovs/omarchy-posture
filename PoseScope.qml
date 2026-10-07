import QtQuick
import "Model.mjs" as Model

// A terminal-style view of your posture: a dotted head-and-shoulders figure
// on a faint grid, built from the seven keypoints.
//
// Muted outline = the slate. Accent dots = you now. Urgent squares = the
// body part a failing check points at. Mirrored like a mirror: your left is
// on the left.
Canvas {
  id: root

  property var kp: null
  property var slateKp: null
  // The slate's own features: what judge() compares against.
  property var slateFeatures: null
  property bool bad: false
  // Matches the slate right now. Shows "GOOD POSTURE".
  property bool good: false
  // Failing check ids ("leanIn", ...). Their body parts turn urgent.
  property var badChecks: []

  // Theme colours, set by the parent from Color.*.
  property color accentColor: "white"
  property color alertColor: "red"
  property color mutedColor: "gray"
  property color textColor: "white"
  property string fontFamily: "monospace"
  property real fontSize: 10

  onKpChanged: requestPaint()
  onSlateKpChanged: requestPaint()
  onBadChanged: requestPaint()
  onGoodChanged: requestPaint()
  onBadChecksChanged: requestPaint()
  onAccentColorChanged: requestPaint()
  onAlertColorChanged: requestPaint()
  onMutedColorChanged: requestPaint()
  onTextColorChanged: requestPaint()
  onFontFamilyChanged: requestPaint()
  onFontSizeChanged: requestPaint()
  onSlateFeaturesChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  readonly property real pad: 10
  // Dot pitch of the figure. The outline is sampled at half of it.
  readonly property int pitch: 6
  // The figure stays below the title line.
  readonly property real ceiling: pad + fontSize + 6

  // Drawn only when the judge would use it too.
  function valid(k) {
    return typeof Model.features(k) !== "string"
  }

  // Frame transform from the reference pose: shoulder midpoint low in the
  // view, shoulder width about 40% of it.
  function frameOf(ref) {
    var ls = ref[5], rs = ref[6]
    var sw = Math.max(1, Math.hypot(ls[0] - rs[0], ls[1] - rs[1]))
    return {
      cx: (ls[0] + rs[0]) / 2,
      cy: (ls[1] + rs[1]) / 2,
      s: Math.min(root.width * 0.36, root.height * 0.48) / sw,
      ox: root.width / 2,
      oy: root.height * 0.66
    }
  }

  function mapper(f) {
    return function(p) { return [f.ox - (p[0] - f.cx) * f.s, f.oy + (p[1] - f.cy) * f.s] }
  }

  function clamp01(v) {
    return v < 0 ? 0 : (v > 1 ? 1 : v)
  }

  // Distance from (x, y) to the segment a-b.
  function segDist(x, y, a, b) {
    var dx = b[0] - a[0], dy = b[1] - a[1]
    var t = clamp01(((x - a[0]) * dx + (y - a[1]) * dy) / Math.max(1e-6, dx * dx + dy * dy))
    return Math.hypot(x - a[0] - t * dx, y - a[1] - t * dy)
  }

  function polyDist(x, y, pts) {
    var d = Infinity
    for (var i = 0; i + 1 < pts.length; i++) d = Math.min(d, segDist(x, y, pts[i], pts[i + 1]))
    return d
  }

  // The figure in screen space. Shoulders and eyes are ordered left to right
  // on screen. Body shapes live in a shoulder frame (U across, V down) in
  // shoulder widths, so a tilted shoulder line tilts the whole torso.
  // `headRatio` (head half-width per shoulder width) comes from the slate:
  // a turned head brings the eyes together, but the skull stays its size.
  function figure(k, px, headRatio) {
    var a5 = px(k[5]), a6 = px(k[6]), e1 = px(k[1]), e2 = px(k[2]), nose = px(k[0])
    var sL = a5[0] < a6[0] ? a5 : a6, sR = a5[0] < a6[0] ? a6 : a5
    var eL = e1[0] < e2[0] ? e1 : e2, eR = e1[0] < e2[0] ? e2 : e1
    var sd = Math.hypot(sR[0] - sL[0], sR[1] - sL[1])
    var esd = Math.hypot(eR[0] - eL[0], eR[1] - eL[1])
    // Unit axes from the true distances. Points that land on one pixel (a
    // head in profile) fall back to level.
    var ux = sd > 1e-6 ? (sR[0] - sL[0]) / sd : 1, uy = sd > 1e-6 ? (sR[1] - sL[1]) / sd : 0
    var hx = esd > 1e-6 ? (eR[0] - eL[0]) / esd : 1, hy = esd > 1e-6 ? (eR[1] - eL[1]) / esd : 0
    var sw = Math.max(1, sd), ed = Math.max(1, esd)
    var ha = headRatio ? sw * headRatio : Math.max(ed * 1.3, sw * 0.17)
    var hb = ha * 1.32
    var eyeMid = [(eL[0] + eR[0]) / 2, (eL[1] + eR[1]) / 2]
    var o = [(sL[0] + sR[0]) / 2, (sL[1] + sR[1]) / 2]
    // A turned face slides toward one side of the skull. Move the skull back.
    var turn = (nose[0] - eyeMid[0]) * hx + (nose[1] - eyeMid[1]) * hy
    var hc = [eyeMid[0] + hy * hb * 0.12 - hx * turn, eyeMid[1] - hx * hb * 0.12 - hy * turn]
    var nw = ha * 0.62 / sw
    var f = {
      sw: sw, o: o, ux: ux, uy: uy, hx: hx, hy: hy, ha: ha, hb: hb, hc: hc,
      nw: nw, sL: sL, sR: sR
    }
    // Screen point of a shoulder-frame point.
    f.at = function(U, V) {
      return [o[0] + (U * ux - V * uy) * sw, o[1] + (U * uy + V * ux) * sw]
    }
    f.chin = [hc[0] - hy * hb * 0.85, hc[1] + hx * hb * 0.85]
    return f
  }

  function inHead(f, x, y) {
    var dx = x - f.hc[0], dy = y - f.hc[1]
    var p = (dx * f.hx + dy * f.hy) / f.ha, q = (-dx * f.hy + dy * f.hx) / f.hb
    return p * p + q * q <= 1
  }

  function inBody(f, x, y) {
    if (inHead(f, x, y)) return true
    var dx = x - f.o[0], dy = y - f.o[1]
    var U = (dx * f.ux + dy * f.uy) / f.sw, V = (-dx * f.uy + dy * f.ux) / f.sw
    var au = Math.abs(U)
    // Neck: a band from the head centre down to the shoulder line.
    if (V < 0 && segDist(x, y, f.hc, f.o) <= f.nw * f.sw) return true
    // Trapezius: falls from the neck, flattens toward the shoulder.
    if (au <= 0.5) {
      var s = clamp01((au - f.nw) / (0.5 - f.nw))
      if (V >= -0.26 + 0.24 * Math.sqrt(s)) return true
    }
    // Deltoid cap, then the upper arm down to the edge of the view.
    var cu = au - 0.44, cv = V - 0.13
    if (cu * cu + cv * cv <= 0.15 * 0.15) return true
    return V >= 0.13 && au <= 0.59 + 0.03 * V
  }

  // 0..1: how much a failing check points at this spot. Bands along the
  // strained part, like a heat map.
  function strain(f, x, y, checks, sides) {
    var w = 0, r = f.sw * 0.13
    for (var i = 0; i < checks.length; i++) {
      var id = checks[i], d = Infinity
      if (id === "leanIn") {
        // Forward head: neck and the top of both trapezius.
        d = polyDist(x, y, [f.at(-0.3, -0.13), f.at(-f.nw, -0.23), f.chin, f.at(f.nw, -0.23), f.at(0.3, -0.13)])
      } else if (id === "headDrop") {
        // Head sinking toward the shoulders: the neck, chin to collar.
        d = Math.min(segDist(x, y, f.chin, f.at(0, -0.04)),
                     polyDist(x, y, [f.at(-f.nw * 1.3, -0.1), f.at(0, -0.04), f.at(f.nw * 1.3, -0.1)]))
      } else if (id === "headTilt") {
        // Tilt: the stretched side of the neck, from the ear down.
        for (var t = -1; t <= 1; t += 2) {
          if (sides.head && t !== sides.head) continue
          var ear = [f.hc[0] + t * f.hx * f.ha * 0.9 - f.hy * f.hb * 0.2, f.hc[1] + t * f.hy * f.ha * 0.9 + f.hx * f.hb * 0.2]
          d = Math.min(d, polyDist(x, y, [ear, f.at(t * f.nw, -0.26), f.at(t * 0.3, -0.18)]))
        }
      } else if (id === "sideLean") {
        // Asymmetry: neck to shoulder on the raised side.
        for (var u = -1; u <= 1; u += 2) {
          if (sides.shoulder && u !== sides.shoulder) continue
          d = Math.min(d, polyDist(x, y, [f.at(u * 0.05, -0.34), f.at(u * f.nw, -0.25), f.at(u * 0.45, -0.04), f.at(u * 0.56, 0.08), f.at(u * 0.58, 0.2)]))
        }
      }
      w = Math.max(w, 1 - d / r)
    }
    return w
  }

  // Stable per-dot noise, so a strain band frays the same way every frame.
  function noise(i, j) {
    var n = Math.sin(i * 12.9898 + j * 78.233) * 43758.5453
    return n - Math.floor(n)
  }

  // Sample the figure on a half-pitch grid. Edge points (an inside point
  // with an outside neighbour) make the dense outline. Every other point
  // inside makes the sparse fill.
  function sample(f, bottom) {
    var h = root.pitch / 2
    // Head and shoulders only: the figure ends just below the shoulder line.
    bottom = Math.min(bottom, f.o[1] + f.sw * 0.3)
    var r = f.sw * 0.66, hr = Math.max(f.ha, f.hb) * 1.2
    // The figure's box, cut to the canvas. Cells past a cut are asked
    // directly, so the cut leaves no false outline.
    var i0 = Math.max(-2, Math.floor(Math.min(f.o[0] - r, f.hc[0] - hr) / h))
    var i1 = Math.min(Math.ceil(root.width / h) + 2, Math.ceil(Math.max(f.o[0] + r, f.hc[0] + hr) / h))
    var j0 = Math.max(Math.floor(root.ceiling / h) - 2, Math.floor((f.hc[1] - hr) / h))
    var j1 = Math.floor(bottom / h)
    var cols = i1 - i0 + 1, rows = j1 - j0 + 1
    if (cols <= 0 || rows <= 0) return { pts: [], bottom: bottom }
    var grid = []
    for (var j = 0; j < rows; j++)
      for (var i = 0; i < cols; i++)
        grid.push(inBody(f, (i0 + i) * h, (j0 + j) * h))
    function at(ci, cj) {
      if (ci >= 0 && ci < cols && cj >= 0 && cj < rows) return grid[cj * cols + ci]
      return inBody(f, (i0 + ci) * h, (j0 + cj) * h)
    }
    var pts = []
    for (j = 0; j < rows; j++) {
      for (i = 0; i < cols; i++) {
        var gi = i0 + i, gj = j0 + j
        if (!grid[j * cols + i] || gj * h < root.ceiling) continue
        var edge = !at(i - 1, j) || !at(i + 1, j) || !at(i, j - 1) || (j < rows - 1 && !at(i, j + 1))
        if (edge || (((gi % 2) + 2) % 2 === 0 && ((gj % 2) + 2) % 2 === 0))
          pts.push({ x: gi * h, y: gj * h, i: gi, j: gj, edge: edge })
      }
    }
    return { pts: pts, bottom: bottom }
  }

  // Fade the figure out toward the bottom of the view.
  function fade(y, bottom) {
    return clamp01((bottom - y) / (root.pitch * 4))
  }

  function drawGhost(ctx, f, bottom, alpha) {
    var sm = sample(f, bottom), pts = sm.pts
    bottom = sm.bottom
    ctx.fillStyle = root.mutedColor
    for (var n = 0; n < pts.length; n++) {
      var p = pts[n]
      if (!p.edge) continue
      ctx.globalAlpha = alpha * fade(p.y, bottom)
      ctx.fillRect(p.x, p.y, 1.5, 1.5)
    }
  }

  function drawFigure(ctx, f, bottom, col, checks, sides) {
    var sm = sample(f, bottom), pts = sm.pts
    bottom = sm.bottom
    var hot = []
    for (var n = 0; n < pts.length; n++) {
      var p = pts[n]
      var w = checks.length ? strain(f, p.x, p.y, checks, sides) : 0
      if (w > 0.1 + 0.5 * noise(p.i, p.j)) {
        hot.push(p)
        continue
      }
      ctx.fillStyle = col
      ctx.globalAlpha = (p.edge ? 1 : 0.5) * fade(p.y, bottom)
      ctx.fillRect(p.x, p.y, 2, 2)
    }
    // Strain squares on top, a little larger.
    ctx.fillStyle = root.alertColor
    for (n = 0; n < hot.length; n++) {
      ctx.globalAlpha = fade(hot[n].y, bottom)
      ctx.fillRect(hot[n].x - 0.5, hot[n].y - 0.5, 3, 3)
    }
  }

  function drawGrid(ctx) {
    ctx.fillStyle = root.mutedColor
    ctx.globalAlpha = 0.22
    var step = 12
    for (var x = root.pad + step; x < root.width - root.pad; x += step)
      for (var y = root.pad + step; y < root.height - root.pad; y += step)
        ctx.fillRect(Math.round(x), Math.round(y), 1, 1)

    // Frame with accent corner ticks.
    ctx.globalAlpha = 0.35
    ctx.strokeStyle = root.mutedColor
    ctx.lineWidth = 1
    ctx.strokeRect(0.5, 0.5, root.width - 1, root.height - 1)
    ctx.globalAlpha = 0.9
    ctx.strokeStyle = root.accentColor
    var t = 8, w = root.width - 0.5, h = root.height - 0.5
    var corners = [[0.5, 0.5, 1, 1], [w, 0.5, -1, 1], [0.5, h, 1, -1], [w, h, -1, -1]]
    for (var i = 0; i < corners.length; i++) {
      var c = corners[i]
      ctx.beginPath()
      ctx.moveTo(c[0] + c[2] * t, c[1])
      ctx.lineTo(c[0], c[1])
      ctx.lineTo(c[0], c[1] + c[3] * t)
      ctx.stroke()
    }
  }

  function text(ctx, s, x, y, col, alpha, align) {
    ctx.globalAlpha = alpha
    ctx.fillStyle = col
    ctx.textAlign = align || "left"
    ctx.fillText(s, x, y)
  }

  function signed(v, unit) {
    var n = Math.round(v)
    return (n > 0 ? "+" : "") + n + unit
  }

  // -1 when the screen-left point of a pair rose against the slate, 1 when
  // the right one did, 0 when neither clearly did (about 3 degrees), so a
  // reason still standing after the user sat straight does not flicker.
  // The mapper flips x, so the screen-left point has the larger image x.
  function raisedSide(now, slate, ia, ib) {
    function drop(k) {
      var a = k[ia], b = k[ib]
      var l = a[0] > b[0] ? a : b, r = a[0] > b[0] ? b : a
      return (r[1] - l[1]) / Math.max(1, Math.hypot(a[0] - b[0], a[1] - b[1]))
    }
    var d = drop(now) - (slate ? drop(slate) : 0)
    return d > 0.05 ? -1 : (d < -0.05 ? 1 : 0)
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.font = Math.round(root.fontSize) + "px \"" + root.fontFamily + "\""
    ctx.textBaseline = "alphabetic"
    drawGrid(ctx)

    var haveSlate = valid(root.slateKp)
    var haveNow = valid(root.kp)
    var checks = root.badChecks || []
    var live = root.bad || checks.length ? root.alertColor : root.accentColor
    var top = root.pad + root.fontSize
    var bottom = root.height - root.pad

    // Title: what is wrong, in the style of a status line.
    var title = !haveNow ? "NO SIGNAL"
      : checks.length ? checks.map(function(id) { return Model.checkLabel(id).toUpperCase() }).join(" · ")
      : root.good ? "GOOD POSTURE" : "LIVE"
    // Too many failed checks to name in one line: say so instead.
    if (checks.length && root.pad + root.fontSize * 1.4 + ctx.measureText(title).width > root.width - root.pad) title = "BAD POSTURE"
    var titleCol = haveNow ? live : root.mutedColor
    text(ctx, haveNow ? "●" : "○", root.pad, top, titleCol, 1)
    text(ctx, title, root.pad + root.fontSize * 1.4, top, titleCol, 1)
    var titleEnd = root.pad + root.fontSize * 1.4 + ctx.measureText(title).width
    var slateLabel = "┄ SLATE"
    // A long list of failed checks wins over the slate label.
    if (haveSlate && titleEnd + root.fontSize < root.width - root.pad - ctx.measureText(slateLabel).width)
      text(ctx, slateLabel, root.width - root.pad, top, root.mutedColor, 1, "right")

    if (!haveSlate) text(ctx, "NO SLATE", root.width - root.pad, bottom, root.mutedColor, 0.8, "right")
    var ref = haveSlate ? root.slateKp : (haveNow ? root.kp : null)
    if (!ref) return
    var px = mapper(frameOf(ref))
    var floor = bottom - root.fontSize - 6

    var sf = haveSlate ? figure(root.slateKp, px) : null
    if (sf) drawGhost(ctx, sf, floor, haveNow ? 0.7 : 1)
    if (haveNow) {
      var sk = haveSlate ? root.slateKp : null
      // A head tilting right stretches the left of the neck: the raised eye's side.
      var sides = { shoulder: raisedSide(root.kp, sk, 5, 6), head: raisedSide(root.kp, sk, 1, 2) }
      drawFigure(ctx, figure(root.kp, px, sf ? sf.ha / sf.sw : 0), floor, root.accentColor, checks, sides)
    }

    // Readouts: change from the slate. Minus means closer or shorter.
    if (haveSlate && haveNow) {
      var fn = Model.features(root.kp)
      if (root.slateFeatures && typeof fn !== "string") {
        var v = Model.checkValues(fn, root.slateFeatures)
        text(ctx, "DIST " + signed(-v.leanIn, "%") + "  NECK " + signed(-v.headDrop, "%"), root.pad, bottom, root.textColor, 0.8)
        text(ctx, "HEAD " + Math.round(v.headTilt) + "°  SHLD " + Math.round(v.sideLean) + "°", root.width - root.pad, bottom, root.textColor, 0.8, "right")
      }
    }
  }
}
