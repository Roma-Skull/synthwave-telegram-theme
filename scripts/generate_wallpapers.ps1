#requires -Version 5.1
<#
.SYNOPSIS
    Generates procedural Neon Horizon Synthwave chat wallpapers for Windows and Android
    Telegram clients, plus a side-by-side UI preview image.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

Add-Type -AssemblyName System.Drawing

$csharpSource = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace SynthwaveTelegramAssets
{
    public static class WallpaperGenerator
    {
        private static readonly int[,] Bayer4x4 = {
            {  0,  8,  2, 10 },
            { 12,  4, 14,  6 },
            {  3, 11,  1,  9 },
            { 15,  7, 13,  5 }
        };

        private static byte ClampByte(double v)
        {
            if (v <= 0.0) return 0;
            if (v >= 255.0) return 255;
            return (byte)(v + 0.5);
        }

        private static double SmoothStep(double edge0, double edge1, double x)
        {
            if (Math.Abs(edge1 - edge0) < 1e-12) return x >= edge1 ? 1.0 : 0.0;
            double t = Math.Max(0.0, Math.Min(1.0, (x - edge0) / (edge1 - edge0)));
            return t * t * (3.0 - 2.0 * t);
        }

        private static double Frac(double x) { return x - Math.Floor(x); }

        private static double Hash11(double p)
        {
            p = Frac(p * 0.1031);
            p *= p + 33.33;
            p *= p + p;
            return Frac(p);
        }

        private static double SdSegment(double px, double py, double ax, double ay, double bx, double by)
        {
            double pax = px - ax, pay = py - ay;
            double bax = bx - ax, bay = by - ay;
            double denom = Math.Max(1e-6, bax * bax + bay * bay);
            double h = Math.Max(0.0, Math.Min(1.0, (pax * bax + pay * bay) / denom));
            double dx = pax - bax * h, dy = pay - bay * h;
            return Math.Sqrt(dx * dx + dy * dy);
        }

        private static double MtnHeight(double idx, double side)
        {
            double x = Math.Abs(idx) * 0.105;
            double envelope = SmoothStep(0.18, 0.52, x) * (0.55 + 0.45 * Hash11(idx * 3.17 + side * 19.7));
            return (0.042 + 0.088 * Hash11(idx * 7.41 + side * 11.3)) * envelope;
        }

        private static double MtnPeakOffset(double idx, double side)
        {
            return (Hash11(idx * 5.23 + side * 31.1) - 0.5) * 0.042;
        }

        private static void EnsureDir(string filePath)
        {
            string dir = Path.GetDirectoryName(filePath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                Directory.CreateDirectory(dir);
        }

        private static void SaveJpeg(Bitmap bmp, string outputPath, long quality)
        {
            EnsureDir(outputPath);
            ImageCodecInfo jpgEncoder = ImageCodecInfo.GetImageEncoders()
                .First(c => c.FormatID == ImageFormat.Jpeg.Guid);
            using (var encParams = new EncoderParameters(1))
            {
                encParams.Param[0] = new EncoderParameter(Encoder.Quality, quality);
                bmp.Save(outputPath, jpgEncoder, encParams);
            }
        }

        public static void BuildChatWallpaper(
            string outputPath,
            int targetWidth,
            int targetHeight,
            double horFromBottom,
            double refScalePx,
            double chatDimFactor,
            int seed,
            long jpegQuality)
        {
            using (var bmp = new Bitmap(targetWidth, targetHeight, PixelFormat.Format24bppRgb))
            {
                var rect = new Rectangle(0, 0, targetWidth, targetHeight);
                var data = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
                int stride = data.Stride;
                byte[] buf = new byte[stride * targetHeight];

                double horY = targetHeight - horFromBottom;
                double pxScale = 1.0 / refScalePx;
                double sunCenterY = 0.065;
                double sunR = 0.185;

                // Seeded starfield across upper sky
                var rng = new Random(seed);
                double[] starMask = new double[targetWidth * targetHeight];
                int[] starKind = new int[targetWidth * targetHeight];
                double sunCxPx = targetWidth * 0.5;
                double sunCyPx = horY - sunCenterY * refScalePx;
                double sunAvoidRPx = sunR * refScalePx * 1.25;
                int starCount = Math.Max(180, (targetWidth * targetHeight) / 11000);
                int maxStarY = Math.Max(40, (int)horY - 12);

                for (int i = 0; i < starCount; i++)
                {
                    int sx = rng.Next(4, targetWidth - 4);
                    int sy = rng.Next(12, maxStarY);
                    double dx = sx - sunCxPx;
                    double dy = sy - sunCyPx;
                    if (dx * dx + dy * dy < sunAvoidRPx * sunAvoidRPx) continue;

                    double topFade = SmoothStep(8.0, 90.0, sy);
                    double horFade = SmoothStep(12.0, 110.0, horY - sy);
                    double bright = (0.24 + rng.NextDouble() * 0.72) * topFade * horFade;
                    int kind = rng.Next(4);
                    starMask[sy * targetWidth + sx] = Math.Max(starMask[sy * targetWidth + sx], bright);
                    starKind[sy * targetWidth + sx] = kind;

                    if (bright > 0.58 && sx > 2 && sx < targetWidth - 3 && sy > 2 && sy < targetHeight - 3)
                    {
                        double arm = bright * 0.36;
                        starMask[sy * targetWidth + (sx - 1)] = Math.Max(starMask[sy * targetWidth + (sx - 1)], arm);
                        starMask[sy * targetWidth + (sx + 1)] = Math.Max(starMask[sy * targetWidth + (sx + 1)], arm);
                        starMask[(sy - 1) * targetWidth + sx] = Math.Max(starMask[(sy - 1) * targetWidth + sx], arm);
                        starMask[(sy + 1) * targetWidth + sx] = Math.Max(starMask[(sy + 1) * targetWidth + sx], arm);
                    }
                }

                // Deep void sky base (#0B0718)
                double skyBaseR = 11.0 / 255.0;
                double skyBaseG = 7.0 / 255.0;
                double skyBaseB = 24.0 / 255.0;

                Parallel.For(0, targetHeight, y =>
                {
                    double pY = (horY - y) * pxScale;
                    double tSky = Math.Max(0.0, Math.Min(1.0, (horY - y) / (horY * 0.92)));
                    double ny = (double)y / targetHeight;

                    // Subtle CRT scanline texture across grid/horizon
                    double scanMul = 1.0;
                    if (pY < -0.02)
                    {
                        double phase = (y % 6) / 6.0;
                        double wBell = Math.Abs(phase * 2.0 - 1.0);
                        double waveY = wBell * wBell * (3.0 - 2.0 * wBell);
                        scanMul = 1.0 - 0.035 * (1.0 - waveY);
                    }

                    // Sky gradient row
                    double sMid = SmoothStep(0.0, 0.36, tSky);
                    double sTop = SmoothStep(0.26, 0.92, tSky);
                    double baseSkyR = 0.245 + (0.088 - 0.245) * sMid;
                    double baseSkyG = 0.055 + (0.039 - 0.055) * sMid;
                    double baseSkyB = 0.305 + (0.195 - 0.305) * sMid;
                    baseSkyR += (skyBaseR - baseSkyR) * sTop;
                    baseSkyG += (skyBaseG - baseSkyG) * sTop;
                    baseSkyB += (skyBaseB - baseSkyB) * sTop;

                    // Floor row constants
                    double yFloorRaw = -pY;
                    double yFloor = Math.Max(0.0022, yFloorRaw);
                    double depth = 0.25 / yFloor;
                    double worldZ = depth - 0.35;
                    double derivX = pxScale * depth * 1.75;
                    double derivZ = Math.Max(0.0008, pxScale * 0.25 / (yFloor * yFloor));
                    double gFracZ = Math.Abs(Frac(worldZ) - 0.5) / derivZ;
                    double distFade = SmoothStep(0.004, 0.032, yFloorRaw);
                    double floorT = SmoothStep(0.0, 0.42, yFloorRaw);
                    double floorBgR = 0.095 + (0.035 - 0.095) * floorT;
                    double floorBgG = 0.026 + (0.016 - 0.026) * floorT;
                    double floorBgB = 0.205 + (0.082 - 0.205) * floorT;
                    double gridMix = Math.Exp(-yFloorRaw * 5.0);
                    double gridColR = 1.0 + (0.0 - 1.0) * gridMix;
                    double gridColG = 0.18 + (0.94 - 0.18) * gridMix;
                    double gridColB = 0.72 + (1.0 - 0.72) * gridMix;
                    double sunTrackY = SmoothStep(0.45, 0.0, yFloorRaw);

                    double horGlow = Math.Exp(-Math.Abs(pY) * 135.0) * 0.48;
                    double horCore = Math.Exp(-Math.Abs(pY) * 520.0) * 0.78;
                    double horAddG = 0.94 * (horGlow + horCore);
                    double horAddB = 1.00 * (horGlow + horCore);

                    int rowOffset = y * stride;
                    int starRowOffset = y * targetWidth;

                    for (int x = 0; x < targetWidth; x++)
                    {
                        double pX = (x - targetWidth * 0.5) * pxScale;
                        double nx = (double)x / targetWidth;
                        double r, g, b;

                        if (pY >= -0.002)
                        {
                            r = baseSkyR;
                            g = baseSkyG;
                            b = baseSkyB;

                            // Subtle atmospheric aurora bands
                            double aurora = Math.Sin(pX * 3.1 + 0.4) * Math.Cos(pY * 7.5 - 0.3);
                            if (aurora > 0.0 && tSky < 1.0)
                            {
                                double af = aurora * (1.0 - tSky);
                                r += 0.045 * af;
                                g += 0.012 * af;
                                b += 0.075 * af;
                            }

                            // Outrun Sun + Corona
                            double pSunY = pY - sunCenterY;
                            double sunDist = Math.Sqrt(pX * pX + pSunY * pSunY);
                            double corona = Math.Exp(-Math.Max(0.0, sunDist - sunR) * 9.5) * 0.58;
                            double wgX = pX * 0.75, wgY = pSunY * 1.45;
                            double wideGlow = Math.Exp(-Math.Sqrt(wgX * wgX + wgY * wgY) * 2.9) * 0.36;
                            double glowSum = corona + wideGlow;
                            r += 1.00 * glowSum;
                            g += 0.16 * glowSum;
                            b += 0.52 * glowSum;

                            // Stars
                            double st = starMask[starRowOffset + x];
                            if (st > 0.001)
                            {
                                double sunStarFade = SmoothStep(sunR * 0.95, sunR * 1.45, sunDist);
                                double w = st * sunStarFade;
                                int kind = starKind[starRowOffset + x];
                                double sr = kind == 0 ? 0.52 : (kind == 1 ? 1.00 : 0.94);
                                double sg = kind == 0 ? 0.97 : (kind == 1 ? 0.64 : 0.96);
                                double sb = kind == 0 ? 1.00 : (kind == 1 ? 0.92 : 1.00);
                                r += (sr - r) * w;
                                g += (sg - g) * w;
                                b += (sb - b) * w;
                            }

                            // Sliced Outrun Sun Disc
                            double discMask = (1.0 - SmoothStep(sunR - pxScale * 1.5, sunR + pxScale * 1.5, sunDist))
                                * SmoothStep(-pxScale, pxScale * 1.5, pY);
                            if (discMask > 0.001)
                            {
                                double hNorm = Math.Max(0.0, Math.Min(1.0, (pSunY + sunR) / (2.0 * sunR)));
                                double sm = SmoothStep(0.08, 0.52, hNorm);
                                double stp = SmoothStep(0.45, 0.92, hNorm);
                                double dr = 1.0;
                                double dg = 0.165 + (0.42 - 0.165) * sm;
                                double db = 0.52 + (0.26 - 0.52) * sm;
                                dg += (0.91 - dg) * stp;
                                db += (0.37 - db) * stp;

                                double visH = Math.Max(0.0, Math.Min(1.0, (hNorm - 0.335) / 0.35));
                                double slicePhase = Frac(visH * 5.2 + 0.15);
                                double sliceThick = 0.42 + (0.04 - 0.42) * visH;
                                double sliceGap = SmoothStep(sliceThick + 0.04, sliceThick - 0.015, slicePhase)
                                    * (visH <= 0.96 ? 1.0 : 0.0)
                                    * SmoothStep(0.96, 0.80, visH);
                                double dm = discMask * (1.0 - sliceGap);
                                r += (dr - r) * dm;
                                g += (dg - g) * dm;
                                b += (db - b) * dm;
                            }

                            // Low-Poly Wireframe Mountains
                            double xAbs = Math.Abs(pX);
                            if (pY >= 0.0 && xAbs >= 0.17)
                            {
                                double side = pX >= 0.0 ? 1.0 : -1.0;
                                double cellW = 0.105;
                                double idx = Math.Floor(xAbs / cellW);
                                double xL = idx * cellW;
                                double xR = (idx + 1.0) * cellW;
                                double hL = MtnHeight(idx, side);
                                double hR = MtnHeight(idx + 1.0, side);
                                double xP = (idx + 0.5) * cellW + MtnPeakOffset(idx, side);
                                double hP = MtnHeight(idx + 0.5, side) * 1.24;
                                double xB = (idx + 0.5) * cellW;

                                double ridgeY = xAbs < xP
                                    ? hL + (hP - hL) * Math.Max(0.0, Math.Min(1.0, (xAbs - xL) / Math.Max(1e-5, xP - xL)))
                                    : hP + (hR - hP) * Math.Max(0.0, Math.Min(1.0, (xAbs - xP) / Math.Max(1e-5, xR - xP)));

                                if (pY <= ridgeY + pxScale * 3.0)
                                {
                                    double inside = 1.0 - SmoothStep(ridgeY - pxScale * 1.1, ridgeY + pxScale * 1.1, pY);
                                    double dRidge = Math.Min(SdSegment(xAbs, pY, xL, hL, xP, hP), SdSegment(xAbs, pY, xP, hP, xR, hR));
                                    double dMesh = Math.Min(
                                        SdSegment(xAbs, pY, xP, hP, xB, 0.0),
                                        Math.Min(SdSegment(xAbs, pY, xL, hL, xB, 0.0), SdSegment(xAbs, pY, xR, hR, xB, 0.0))
                                    );
                                    double wireRidge = 1.0 - SmoothStep(pxScale * 0.7, pxScale * 2.1, dRidge);
                                    double wireInner = (1.0 - SmoothStep(pxScale * 0.45, pxScale * 1.6, dMesh)) * inside;

                                    double facet = xAbs < xP ? 0.0 : 1.0;
                                    double darkR = 0.032 + (0.052 - 0.032) * facet;
                                    double darkG = 0.014 + (0.020 - 0.014) * facet;
                                    double darkB = 0.072 + (0.115 - 0.072) * facet;
                                    double sunProx = Math.Exp(-Math.Sqrt(pX * pX + (pY - sunCenterY) * (pY - sunCenterY)) * 2.4) * 0.35;
                                    darkR += 0.14 * sunProx;
                                    darkG += 0.02 * sunProx;
                                    darkB += 0.12 * sunProx;

                                    double wm = SmoothStep(0.20, 0.70, xAbs) * 0.65 + SmoothStep(0.01, 0.09, pY) * 0.35;
                                    double wireR = 0.88 + (0.00 - 0.88) * wm;
                                    double wireG = 0.22 + (0.94 - 0.22) * wm;
                                    double wireB = 0.96 + (1.00 - 0.96) * wm;

                                    double ws = wireRidge * 0.95 + wireInner * 0.55;
                                    double mtnR = darkR + wireR * ws;
                                    double mtnG = darkG + wireG * ws;
                                    double mtnB = darkB + wireB * ws;

                                    r = r + (mtnR - r) * inside;
                                    g = g + (mtnG - g) * inside;
                                    b = b + (mtnB - b) * inside;

                                    double rimAdd = wireRidge * 0.32 * (1.0 - inside);
                                    g += 0.94 * rimAdd;
                                    b += 1.00 * rimAdd;
                                }
                            }
                        }
                        else
                        {
                            // Perspective Neon Floor Grid
                            double worldX = pX * depth * 1.75;
                            double gFracX = Math.Abs(Frac(worldX) - 0.5) / Math.Max(0.0008, derivX);
                            double dLine = Math.Min(gFracX, gFracZ);
                            double lineCore = 1.0 - Math.Min(dLine, 1.0);
                            double lineHalo = Math.Exp(-dLine * 0.68) * 0.28;
                            double lineStrength = (lineCore * 0.95 + lineHalo) * distFade;

                            double sunTrack = Math.Exp(-pX * pX * 16.0) * sunTrackY * 0.44;
                            r = floorBgR + 0.55 * sunTrack + gridColR * lineStrength;
                            g = floorBgG + 0.12 * sunTrack + gridColG * lineStrength;
                            b = floorBgB + 0.42 * sunTrack + gridColB * lineStrength;
                        }

                        // Electric Cyan Horizon Beam
                        g += horAddG;
                        b += horAddB;

                        // Subtle chat-readability calibration (keeps text/bubbles crisp while retaining vibrant neon)
                        double vx = (nx - 0.5) * 2.0;
                        double vy = (ny - 0.5) * 2.0;
                        double vig = 1.0 - 0.16 * Math.Min(1.0, (vx * vx * 0.55 + vy * vy * 0.45));
                        double mul = chatDimFactor * scanMul * vig;

                        r = Math.Max(0.0, Math.Min(1.0, r)) * mul * 255.0;
                        g = Math.Max(0.0, Math.Min(1.0, g)) * mul * 255.0;
                        b = Math.Max(0.0, Math.Min(1.0, b)) * mul * 255.0;

                        double dither = (Bayer4x4[y & 3, x & 3] / 16.0 - 0.5) * 0.7;
                        int pxIdx = rowOffset + x * 3;
                        buf[pxIdx + 0] = ClampByte(b + dither);
                        buf[pxIdx + 1] = ClampByte(g + dither);
                        buf[pxIdx + 2] = ClampByte(r + dither);
                    }
                });

                Marshal.Copy(buf, 0, data.Scan0, buf.Length);
                bmp.UnlockBits(data);
                SaveJpeg(bmp, outputPath, jpegQuality);
            }
        }

        private static GraphicsPath RoundedRect(RectangleF bounds, float radius)
        {
            var p = new GraphicsPath();
            float d = radius * 2f;
            p.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
            p.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
            p.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
            p.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        private static void FillRounded(Graphics g, Brush b, float x, float y, float w, float h, float r)
        {
            using (var p = RoundedRect(new RectangleF(x, y, w, h), r))
                g.FillPath(b, p);
        }

        private static void DrawRounded(Graphics g, Pen pen, float x, float y, float w, float h, float r)
        {
            using (var p = RoundedRect(new RectangleF(x, y, w, h), r))
                g.DrawPath(pen, p);
        }

        public static void BuildShowcasePreview(string winBgPath, string androidBgPath, string outputPath)
        {
            const int W = 1600;
            const int H = 960;
            EnsureDir(outputPath);

            using (var bmp = new Bitmap(W, H, PixelFormat.Format24bppRgb))
            using (var g = Graphics.FromImage(bmp))
            using (var winBg = Image.FromFile(winBgPath))
            using (var andBg = Image.FromFile(androidBgPath))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

                // Backdrop gradient
                using (var bgBrush = new LinearGradientBrush(
                    new PointF(0, 0), new PointF(W, H),
                    Color.FromArgb(8, 5, 19), Color.FromArgb(24, 11, 52)))
                {
                    g.FillRectangle(bgBrush, 0, 0, W, H);
                }

                // Header bar
                using (var fTitle = new Font("Segoe UI", 26f, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var fSub = new Font("Segoe UI", 14.5f, FontStyle.Regular, GraphicsUnit.Pixel))
                using (var fBadge = new Font("Segoe UI", 12f, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var brWhite = new SolidBrush(Color.FromArgb(242, 248, 255)))
                using (var brCyan = new SolidBrush(Color.FromArgb(0, 240, 255)))
                using (var brMuted = new SolidBrush(Color.FromArgb(184, 164, 222)))
                using (var brMag = new SolidBrush(Color.FromArgb(255, 42, 133)))
                {
                    g.DrawString("NEON HORIZON", fTitle, brWhite, 52, 28);
                    float w1 = g.MeasureString("NEON HORIZON", fTitle).Width;
                    g.DrawString("SYNTHWAVE TELEGRAM THEME", fTitle, brCyan, 52 + w1 + 14, 28);
                    g.DrawString("Windows (Telegram Desktop .tdesktop-theme)  &  Android (Telegram .attheme)", fSub, brMuted, 54, 64);

                    // Top right pill
                    FillRounded(g, new SolidBrush(Color.FromArgb(27, 15, 56)), W - 260, 34, 206, 36, 18);
                    using (var penCyan = new Pen(Color.FromArgb(0, 240, 255), 1.5f))
                        DrawRounded(g, penCyan, W - 260, 34, 206, 36, 18);
                    g.DrawString("OUTRUN 84 PALETTE", fBadge, brCyan, W - 224, 44);
                }

                // =========================================================
                // 1. TELEGRAM DESKTOP MOCKUP (Left)
                // =========================================================
                float dx = 52, dy = 116, dw = 1040, dh = 790;
                using (var winShadow = new SolidBrush(Color.FromArgb(140, 2, 1, 8)))
                    FillRounded(g, winShadow, dx + 8, dy + 12, dw, dh, 16);

                using (var winClip = RoundedRect(new RectangleF(dx, dy, dw, dh), 14))
                {
                    g.SetClip(winClip);

                    // Title bar (#120A26)
                    using (var brTitle = new SolidBrush(Color.FromArgb(18, 10, 38)))
                        g.FillRectangle(brTitle, dx, dy, dw, 34);
                    using (var fSmall = new Font("Segoe UI", 12f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (var brLav = new SolidBrush(Color.FromArgb(184, 164, 222)))
                    {
                        g.DrawString("Telegram Desktop — Neon Horizon", fSmall, brLav, dx + 16, dy + 9);
                    }
                    // Window controls
                    using (var brClose = new SolidBrush(Color.FromArgb(255, 42, 133)))
                        g.FillRectangle(brClose, dx + dw - 44, dy, 44, 34);
                    using (var fCtrl = new Font("Segoe UI", 13f, FontStyle.Regular, GraphicsUnit.Pixel))
                    using (var brW = new SolidBrush(Color.White))
                    {
                        g.DrawString("—", fCtrl, brW, dx + dw - 116, dy + 7);
                        g.DrawString("□", fCtrl, brW, dx + dw - 76, dy + 7);
                        g.DrawString("×", fCtrl, brW, dx + dw - 28, dy + 6);
                    }

                    // Left Folders Sidebar (#090514)
                    float sideW = 72;
                    using (var brSide = new SolidBrush(Color.FromArgb(9, 5, 20)))
                        g.FillRectangle(brSide, dx, dy + 34, sideW, dh - 34);

                    using (var fSide = new Font("Segoe UI", 10.5f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (var brCyan = new SolidBrush(Color.FromArgb(0, 240, 255)))
                    using (var brMuted = new SolidBrush(Color.FromArgb(131, 112, 173)))
                    using (var brActiveSide = new SolidBrush(Color.FromArgb(37, 20, 75)))
                    using (var brMag = new SolidBrush(Color.FromArgb(255, 42, 133)))
                    using (var brW = new SolidBrush(Color.White))
                    {
                        FillRounded(g, brActiveSide, dx + 8, dy + 52, sideW - 16, 56, 10);
                        g.FillRectangle(brCyan, dx + 8, dy + 64, 3, 32);
                        g.DrawString("All", fSide, brCyan, dx + 27, dy + 86);
                        FillRounded(g, brMag, dx + 40, dy + 56, 20, 16, 8);
                        g.DrawString("4", fSide, brW, dx + 46, dy + 57);

                        string[] folders = { "Work", "Dev", "News" };
                        for (int i = 0; i < folders.Length; i++)
                        {
                            float fy = dy + 124 + i * 64;
                            g.DrawEllipse(new Pen(Color.FromArgb(131, 112, 173), 2f), dx + 26, fy, 20, 20);
                            g.DrawString(folders[i], fSide, brMuted, dx + 21, fy + 26);
                        }
                    }

                    // Chats list (#0E0920)
                    float listX = dx + sideW, listW = 300;
                    using (var brList = new SolidBrush(Color.FromArgb(14, 9, 32)))
                        g.FillRectangle(brList, listX, dy + 34, listW, dh - 34);

                    // Search box
                    using (var brSearch = new SolidBrush(Color.FromArgb(27, 15, 56)))
                    using (var fSearch = new Font("Segoe UI", 13f, FontStyle.Regular, GraphicsUnit.Pixel))
                    using (var brMuted = new SolidBrush(Color.FromArgb(131, 112, 173)))
                    {
                        FillRounded(g, brSearch, listX + 14, dy + 48, listW - 28, 36, 18);
                        g.DrawString("Search", fSearch, brMuted, listX + 30, dy + 57);
                    }

                    // Chat items
                    string[] names = { "Synthwave FM", "Neon Dev Lab", "Outrun Club", "Retro Browser", "Night City", "Saved Messages" };
                    string[] msgs = { "Now playing: Midnight Grid", "Release v1.0.0 ready!", "CRT shader looks crisp", "Pushed to GitHub main", "See you at the horizon", "palette.json backed up" };
                    string[] times = { "20:48", "20:42", "19:15", "18:04", "16:30", "12:00" };
                    Color[] avColors = {
                        Color.FromArgb(255, 42, 133),
                        Color.FromArgb(0, 240, 255),
                        Color.FromArgb(181, 55, 242),
                        Color.FromArgb(255, 148, 77),
                        Color.FromArgb(71, 245, 184),
                        Color.FromArgb(56, 232, 255)
                    };

                    using (var fName = new Font("Segoe UI", 14f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (var fMsg = new Font("Segoe UI", 12.5f, FontStyle.Regular, GraphicsUnit.Pixel))
                    using (var fTime = new Font("Segoe UI", 11f, FontStyle.Regular, GraphicsUnit.Pixel))
                    using (var brW = new SolidBrush(Color.FromArgb(242, 248, 255)))
                    using (var brSub = new SolidBrush(Color.FromArgb(184, 164, 222)))
                    using (var brCyan = new SolidBrush(Color.FromArgb(0, 240, 255)))
                    using (var brMag = new SolidBrush(Color.FromArgb(255, 42, 133)))
                    {
                        for (int i = 0; i < names.Length; i++)
                        {
                            float iy = dy + 98 + i * 74;
                            if (i == 1)
                            {
                                using (var brAct = new SolidBrush(Color.FromArgb(45, 22, 89)))
                                    g.FillRectangle(brAct, listX, iy, listW, 72);
                            }
                            using (var brAv = new SolidBrush(avColors[i]))
                                g.FillEllipse(brAv, listX + 14, iy + 13, 46, 46);
                            g.DrawString(names[i].Substring(0, 1), fName, new SolidBrush(Color.FromArgb(11, 7, 24)), listX + 31, iy + 27);
                            g.DrawString(names[i], fName, brW, listX + 72, iy + 14);
                            g.DrawString(times[i], fTime, i == 1 ? brCyan : brSub, listX + listW - 46, iy + 16);
                            g.DrawString(msgs[i], fMsg, i == 1 ? new SolidBrush(Color.FromArgb(224, 246, 255)) : brSub, listX + 72, iy + 39);
                            if (i == 0 || i == 2)
                            {
                                FillRounded(g, brMag, listX + listW - 36, iy + 39, 22, 18, 9);
                                g.DrawString(i == 0 ? "3" : "1", fTime, Color.White.A == 255 ? new SolidBrush(Color.White) : brW, listX + listW - 29, iy + 40);
                            }
                        }
                    }

                    // Chat area with Neon Horizon wallpaper
                    float chatX = listX + listW, chatW = dw - sideW - listW;
                    float chatTopH = 56, composeH = 56;
                    g.DrawImage(winBg, chatX, dy + 34 + chatTopH, chatW, dh - 34 - chatTopH - composeH);

                    // Top bar (#120A26)
                    using (var brTop = new SolidBrush(Color.FromArgb(18, 10, 38)))
                        g.FillRectangle(brTop, chatX, dy + 34, chatW, chatTopH);
                    using (var fName = new Font("Segoe UI", 15f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (var fStat = new Font("Segoe UI", 12f, FontStyle.Regular, GraphicsUnit.Pixel))
                    {
                        g.DrawString("Neon Dev Lab", fName, new SolidBrush(Color.FromArgb(242, 248, 255)), chatX + 20, dy + 44);
                        g.DrawString("42 members, 8 online", fStat, new SolidBrush(Color.FromArgb(0, 240, 255)), chatX + 20, dy + 65);
                    }

                    // Date service pill
                    using (var brPill = new SolidBrush(Color.FromArgb(215, 20, 10, 43)))
                    using (var fPill = new Font("Segoe UI", 12f, FontStyle.Bold, GraphicsUnit.Pixel))
                    {
                        FillRounded(g, brPill, chatX + chatW / 2 - 48, dy + 108, 96, 26, 13);
                        g.DrawString("Today", fPill, new SolidBrush(Color.FromArgb(242, 248, 255)), chatX + chatW / 2 - 19, dy + 113);
                    }

                    // Incoming bubble (#150D2B)
                    using (var brIn = new SolidBrush(Color.FromArgb(238, 21, 13, 43)))
                    using (var fSender = new Font("Segoe UI", 12.5f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (var fText = new Font("Segoe UI", 13.5f, FontStyle.Regular, GraphicsUnit.Pixel))
                    using (var fTime = new Font("Segoe UI", 11f, FontStyle.Regular, GraphicsUnit.Pixel))
                    {
                        FillRounded(g, brIn, chatX + 24, dy + 154, 410, 92, 12);
                        g.DrawString("Alex", fSender, new SolidBrush(Color.FromArgb(56, 232, 255)), chatX + 40, dy + 164);
                        g.DrawString("Have you checked the new Neon Horizon", fText, new SolidBrush(Color.FromArgb(242, 248, 255)), chatX + 40, dy + 186);
                        g.DrawString("theme? Cyan links + Outrun sun look unreal!", fText, new SolidBrush(Color.FromArgb(242, 248, 255)), chatX + 40, dy + 207);
                        g.DrawString("20:40", fTime, new SolidBrush(Color.FromArgb(149, 130, 194)), chatX + 388, dy + 225);
                    }

                    // Outgoing bubble (#2A124A -> #3A1766) with reply bar
                    using (var brOut = new LinearGradientBrush(
                        new PointF(chatX + chatW - 440, dy + 266),
                        new PointF(chatX + chatW - 24, dy + 384),
                        Color.FromArgb(242, 58, 23, 102), Color.FromArgb(242, 36, 16, 66)))
                    using (var fReply = new Font("Segoe UI", 12f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (var fText = new Font("Segoe UI", 13.5f, FontStyle.Regular, GraphicsUnit.Pixel))
                    using (var fTime = new Font("Segoe UI", 11f, FontStyle.Regular, GraphicsUnit.Pixel))
                    {
                        float bx = chatX + chatW - 440, by = dy + 266;
                        FillRounded(g, brOut, bx, by, 416, 118, 12);
                        g.FillRectangle(new SolidBrush(Color.FromArgb(0, 240, 255)), bx + 16, by + 14, 3, 34);
                        g.DrawString("Alex", fReply, new SolidBrush(Color.FromArgb(0, 240, 255)), bx + 26, by + 13);
                        g.DrawString("Cyan links + Outrun sun look unreal!", fReply, new SolidBrush(Color.FromArgb(224, 246, 255)), bx + 26, by + 30);
                        g.DrawString("Yes! Works cleanly on Windows & Android.", fText, new SolidBrush(Color.FromArgb(255, 255, 255)), bx + 16, by + 58);
                        g.DrawString("github.com/Roma-Skull/synthwave-telegram-theme", fText, new SolidBrush(Color.FromArgb(72, 236, 255)), bx + 16, by + 80);
                        g.DrawString("20:42  ✓✓", fTime, new SolidBrush(Color.FromArgb(0, 240, 255)), bx + 344, by + 98);
                    }

                    // Compose bar (#140B29)
                    using (var brComp = new SolidBrush(Color.FromArgb(20, 11, 41)))
                        g.FillRectangle(brComp, chatX, dy + dh - composeH, chatW, composeH);
                    using (var fComp = new Font("Segoe UI", 14f, FontStyle.Regular, GraphicsUnit.Pixel))
                        g.DrawString("Write a message...", fComp, new SolidBrush(Color.FromArgb(131, 112, 173)), chatX + 54, dy + dh - 37);
                    g.FillEllipse(new SolidBrush(Color.FromArgb(0, 240, 255)), chatX + chatW - 44, dy + dh - 44, 32, 32);

                    // Subtle border
                    g.ResetClip();
                    using (var penBorder = new Pen(Color.FromArgb(74, 34, 138), 1.5f))
                        DrawRounded(g, penBorder, dx, dy, dw, dh, 14);
                }

                // =========================================================
                // 2. TELEGRAM ANDROID MOCKUP (Right)
                // =========================================================
                float ax = 1136, ay = 116, aw = 412, ah = 790;
                using (var andShadow = new SolidBrush(Color.FromArgb(150, 2, 1, 8)))
                    FillRounded(g, andShadow, ax + 8, ay + 12, aw, ah, 36);

                using (var phoneClip = RoundedRect(new RectangleF(ax, ay, aw, ah), 34))
                {
                    g.SetClip(phoneClip);
                    // Wallpaper behind chat
                    g.DrawImage(andBg, ax, ay + 78, aw, ah - 138);

                    // Action bar (#140A2C)
                    using (var brBar = new SolidBrush(Color.FromArgb(20, 10, 44)))
                        g.FillRectangle(brBar, ax, ay, aw, 86);
                    using (var fBar = new Font("Segoe UI", 16f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (var fSub = new Font("Segoe UI", 12f, FontStyle.Regular, GraphicsUnit.Pixel))
                    {
                        g.FillEllipse(new SolidBrush(Color.FromArgb(0, 240, 255)), ax + 54, ay + 34, 38, 38);
                        g.DrawString("N", fBar, new SolidBrush(Color.FromArgb(11, 7, 24)), ax + 66, ay + 42);
                        g.DrawString("Neon Dev Lab", fBar, new SolidBrush(Color.FromArgb(242, 248, 255)), ax + 104, ay + 34);
                        g.DrawString("8 online", fSub, new SolidBrush(Color.FromArgb(0, 240, 255)), ax + 104, ay + 56);
                    }

                    // Stories / pinned banner pill
                    using (var brPill = new SolidBrush(Color.FromArgb(220, 20, 10, 44)))
                    using (var fPill = new Font("Segoe UI", 12f, FontStyle.Bold, GraphicsUnit.Pixel))
                    {
                        FillRounded(g, brPill, ax + aw / 2 - 44, ay + 102, 88, 24, 12);
                        g.DrawString("Today", fPill, new SolidBrush(Color.FromArgb(242, 248, 255)), ax + aw / 2 - 18, ay + 106);
                    }

                    // Incoming mobile bubble
                    using (var brIn = new SolidBrush(Color.FromArgb(240, 21, 13, 43)))
                    using (var fText = new Font("Segoe UI", 13.5f, FontStyle.Regular, GraphicsUnit.Pixel))
                    using (var fTime = new Font("Segoe UI", 11f, FontStyle.Regular, GraphicsUnit.Pixel))
                    {
                        FillRounded(g, brIn, ax + 16, ay + 146, 300, 78, 16);
                        g.DrawString("Neon Horizon .attheme with", fText, new SolidBrush(Color.FromArgb(242, 248, 255)), ax + 30, ay + 158);
                        g.DrawString("embedded portrait wallpaper!", fText, new SolidBrush(Color.FromArgb(242, 248, 255)), ax + 30, ay + 180);
                        g.DrawString("20:41", fTime, new SolidBrush(Color.FromArgb(149, 130, 194)), ax + 266, ay + 202);
                    }

                    // Outgoing gradient mobile bubble
                    using (var brOut = new LinearGradientBrush(
                        new PointF(ax + 78, ay + 244),
                        new PointF(ax + aw - 16, ay + 344),
                        Color.FromArgb(244, 58, 23, 102), Color.FromArgb(244, 36, 16, 66)))
                    using (var fText = new Font("Segoe UI", 13.5f, FontStyle.Regular, GraphicsUnit.Pixel))
                    using (var fTime = new Font("Segoe UI", 11f, FontStyle.Regular, GraphicsUnit.Pixel))
                    {
                        FillRounded(g, brOut, ax + 78, ay + 244, aw - 94, 96, 16);
                        g.DrawString("Hot magenta + electric cyan", fText, new SolidBrush(Color.White), ax + 94, ay + 258);
                        g.DrawString("ready for Android & Desktop.", fText, new SolidBrush(Color.White), ax + 94, ay + 280);
                        g.DrawString("20:42  ✓✓", fTime, new SolidBrush(Color.FromArgb(0, 240, 255)), ax + aw - 88, ay + 314);
                    }

                    // Compose bar (#140B29)
                    using (var brComp = new SolidBrush(Color.FromArgb(20, 11, 41)))
                        g.FillRectangle(brComp, ax, ay + ah - 64, aw, 64);
                    using (var fComp = new Font("Segoe UI", 14f, FontStyle.Regular, GraphicsUnit.Pixel))
                        g.DrawString("Message", fComp, new SolidBrush(Color.FromArgb(131, 112, 173)), ax + 54, ay + ah - 42);
                    g.FillEllipse(new SolidBrush(Color.FromArgb(255, 42, 133)), ax + aw - 50, ay + ah - 50, 36, 36);

                    g.ResetClip();
                    using (var penPhone = new Pen(Color.FromArgb(0, 240, 255), 2.2f))
                        DrawRounded(g, penPhone, ax, ay, aw, ah, 34);
                }

                // Save PNG
                bmp.Save(outputPath, ImageFormat.Png);
            }
        }
    }
}
'@

Add-Type -TypeDefinition $csharpSource -ReferencedAssemblies System.Drawing

$winBg = Join-Path $RepoRoot 'windows\background.jpg'
$andBg = Join-Path $RepoRoot 'android\background_android.jpg'
$previewPng = Join-Path $RepoRoot 'img\preview.png'

Write-Host 'Generating Windows chat wallpaper (1920x1080)...'
[SynthwaveTelegramAssets.WallpaperGenerator]::BuildChatWallpaper($winBg, 1920, 1080, 440.0, 1080.0, 0.86, 1984, 92)

Write-Host 'Generating Android portrait chat wallpaper (1080x2160)...'
[SynthwaveTelegramAssets.WallpaperGenerator]::BuildChatWallpaper($andBg, 1080, 2160, 880.0, 1080.0, 0.86, 1985, 88)

Write-Host 'Generating UI preview showcase (1600x960)...'
[SynthwaveTelegramAssets.WallpaperGenerator]::BuildShowcasePreview($winBg, $andBg, $previewPng)

Get-Item $winBg, $andBg, $previewPng | Format-Table Name, Length -AutoSize
