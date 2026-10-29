<#
  Hakaine Maiko DE-GROWLED (Embedded Oto & Patched Version)
  Makes a processed COPY of your own Hakaine Maiko voicebank with the rough
  (growled / screamed) noise component replaced by a clean harmonic voice that
  follows the original's vowel colour and loudness.

  - Never modifies the source bank. Never overwrites an existing output folder.
  - Does not contain or redistribute any voicebank audio.
  - Needs Windows PowerShell 5.1 (built into Windows 10/11) and a portable ffmpeg.exe.

  Normally started through Hakaine_Maiko_DE-GROWLED.bat. Optional switches:
    -SourceBank <folder>  -FfmpegPath <ffmpeg.exe>  -Mode Ask|Test|Bank|Oto
    -Oto Regenerate|Keep   (Bank mode: rebuild oto.ini from the processed samples, default Regenerate)
    -Strength Ask|Light|Balanced|Clean|CleanPlus|Flat  -TestFile <wav>  -Pitch <Hz>
    -Organic <0..1, default 0.6>  -Yes  -NoPause
#>
[CmdletBinding()]
param(
    [string]$SourceBank = '',
    [string]$FfmpegPath = '',
    [ValidateSet('Ask', 'Test', 'Bank', 'Oto')][string]$Mode = 'Ask',
    [ValidateSet('Regenerate', 'Keep')][string]$Oto = 'Regenerate',
    [ValidateSet('Ask', 'Light', 'Balanced', 'Clean', 'CleanPlus', 'Flat')][string]$Strength = 'Ask',
    [string]$TestFile = '',
    [string]$TestOutDir = '',
    [double]$Pitch = 140,
    [double]$Organic = 0.6,
    [switch]$Yes,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ToolName = 'Hakaine Maiko DE-GROWLED'
$script:Marker = ([string][char]0x300C) + 'DE-GROWLED' + ([string][char]0x300D)
$script:SkipExt = @('.frq', '.pmk', '.llsm', '.mrq')
$script:WorkDir = ''

# ---------------------------------------------------------------- DSP engine (C#, compiled on the fly)
$csharp = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

public class DegrowlOptions
{
    public double F0 = 140.0;        // clean carrier pitch in Hz
    public double Leak = 0.0;        // 0..1 amount of the original (rough) signal kept in voiced parts
    public int SmoothFrames = 2;     // time smoothing radius for the spectral envelope (5 ms frames)
    public double HfLo = 0.12;       // fraction of energy above 4 kHz where processing starts to fade out
    public double HfHi = 0.40;       // ... and where it is fully bypassed (fricatives, bursts)
    public double EnvMinBwHz = 70.0;  // smoothing width of the measured envelope (Hz, at least)
    public double EnvRelBw = 0.08;    // ... and relative to frequency
    public double Organic = 0.6;     // 0..1 natural pitch drift/jitter, phase wander and breath
    public double Ceiling = 0.97;    // output peak ceiling
    public string DebugFile = null;
}

public class WavData
{
    public int SampleRate;
    public int Channels;
    public int Bits;
    public bool IsFloat;
    public int Frames;
    public float[][] Data;   // [channel][frame]
}

public static class Degrowl
{
    // ------------------------------------------------------------------ WAV I/O
    public static WavData ReadWav(string path)
    {
        byte[] b = File.ReadAllBytes(path);
        if (b.Length < 12 || b[0] != 'R' || b[1] != 'I' || b[2] != 'F' || b[3] != 'F')
            throw new InvalidDataException("Not a RIFF/WAVE file.");
        int pos = 12;
        int tag = 0, ch = 0, sr = 0, bits = 0;
        int dataPos = -1, dataLen = 0;
        while (pos + 8 <= b.Length)
        {
            string id = Encoding.ASCII.GetString(b, pos, 4);
            long len = BitConverter.ToUInt32(b, pos + 4);
            int body = pos + 8;
            if (id == "fmt ")
            {
                tag = BitConverter.ToUInt16(b, body);
                ch = BitConverter.ToUInt16(b, body + 2);
                sr = BitConverter.ToInt32(b, body + 4);
                bits = BitConverter.ToUInt16(b, body + 14);
                if (tag == 0xFFFE && len >= 26) tag = BitConverter.ToUInt16(b, body + 24);
            }
            else if (id == "data")
            {
                dataPos = body;
                long avail = b.Length - body;
                dataLen = (int)Math.Min(len, avail);
                break;
            }
            long next = body + len + (len & 1);
            if (next > b.Length) break;
            pos = (int)next;
        }
        if (dataPos < 0 || ch < 1 || sr < 1) throw new InvalidDataException("Missing fmt/data chunk.");
        bool isFloat = (tag == 3);
        if (tag != 1 && tag != 3) throw new InvalidDataException("Unsupported WAV format tag " + tag + ".");
        int bytes = bits / 8;
        if (bytes < 1) throw new InvalidDataException("Bad bit depth.");
        int frames = dataLen / (bytes * ch);
        WavData w = new WavData();
        w.SampleRate = sr; w.Channels = ch; w.Bits = bits; w.IsFloat = isFloat; w.Frames = frames;
        w.Data = new float[ch][];
        for (int c = 0; c < ch; c++) w.Data[c] = new float[frames];
        int p = dataPos;
        for (int i = 0; i < frames; i++)
        {
            for (int c = 0; c < ch; c++)
            {
                float v;
                if (isFloat)
                {
                    if (bits == 32) v = BitConverter.ToSingle(b, p);
                    else if (bits == 64) v = (float)BitConverter.ToDouble(b, p);
                    else throw new InvalidDataException("Unsupported float depth.");
                }
                else if (bits == 8) v = (b[p] - 128) / 128f;
                else if (bits == 16) v = BitConverter.ToInt16(b, p) / 32768f;
                else if (bits == 24) v = (((b[p] << 8) | (b[p + 1] << 16) | (b[p + 2] << 24)) >> 8) / 8388608f;
                else if (bits == 32) v = BitConverter.ToInt32(b, p) / 2147483648f;
                else throw new InvalidDataException("Unsupported bit depth " + bits + ".");
                w.Data[c][i] = v;
                p += bytes;
            }
        }
        return w;
    }

    public static string Describe(string path)
    {
        WavData w = ReadWav(path);
        string codec = "unknown";
        if (w.IsFloat) codec = (w.Bits == 64) ? "pcm_f64le" : "pcm_f32le";
        else if (w.Bits == 8) codec = "pcm_u8";
        else if (w.Bits == 16) codec = "pcm_s16le";
        else if (w.Bits == 24) codec = "pcm_s24le";
        else if (w.Bits == 32) codec = "pcm_s32le";
        return codec + ";" + w.SampleRate + ";" + w.Channels + ";" + w.Frames;
    }

    public static void WriteTestTone(string path)
    {
        float[][] d = new float[1][];
        d[0] = new float[4410];
        for (int i = 0; i < d[0].Length; i++) d[0][i] = (float)(0.25 * Math.Sin(2 * Math.PI * 220.0 * i / 44100.0));
        WriteWavFloat(path, d, 44100);
    }

    public static void WriteWavFloat(string path, float[][] data, int sampleRate)
    {
        int ch = data.Length;
        int frames = data[0].Length;
        int dataLen = frames * ch * 4;
        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        using (BinaryWriter bw = new BinaryWriter(fs))
        {
            bw.Write(Encoding.ASCII.GetBytes("RIFF"));
            bw.Write(36 + dataLen);
            bw.Write(Encoding.ASCII.GetBytes("WAVE"));
            bw.Write(Encoding.ASCII.GetBytes("fmt "));
            bw.Write(16);
            bw.Write((short)3);
            bw.Write((short)ch);
            bw.Write(sampleRate);
            bw.Write(sampleRate * ch * 4);
            bw.Write((short)(ch * 4));
            bw.Write((short)32);
            bw.Write(Encoding.ASCII.GetBytes("data"));
            bw.Write(dataLen);
            for (int i = 0; i < frames; i++)
                for (int c = 0; c < ch; c++)
                    bw.Write(data[c][i]);
        }
    }

    public static string Process(string inPath, string outPath, DegrowlOptions o)
    {
        WavData w = ReadWav(inPath);
        float[][] outData = new float[w.Channels][];
        double wetSum = 0; int wetCnt = 0;
        double peak = 0;
        for (int c = 0; c < w.Channels; c++)
        {
            double wet;
            outData[c] = ProcessChannel(w.Data[c], w.SampleRate, o, c == 0 ? o.DebugFile : null, out wet);
            wetSum += wet; wetCnt++;
        }
        for (int c = 0; c < w.Channels; c++)
            for (int i = 0; i < outData[c].Length; i++)
                if (float.IsNaN(outData[c][i]) || float.IsInfinity(outData[c][i])) throw new InvalidOperationException("Processing produced invalid samples.");
        Limit(outData, o.Ceiling);
        for (int c = 0; c < w.Channels; c++)
            for (int i = 0; i < outData[c].Length; i++) { double a = Math.Abs(outData[c][i]); if (a > peak) peak = a; }
        WriteWavFloat(outPath, outData, w.SampleRate);
        return string.Format("wet={0:F2} peak={1:F3}", wetSum / Math.Max(1, wetCnt), peak);
    }

    internal static void Fft(double[] re, double[] im)
    {
        int n = re.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
        }
        for (int len = 2; len <= n; len <<= 1)
        {
            double ang = -2 * Math.PI / len;
            double wr = Math.Cos(ang), wi = Math.Sin(ang);
            for (int i = 0; i < n; i += len)
            {
                double cr = 1, ci = 0;
                for (int k = 0; k < len / 2; k++)
                {
                    int u = i + k, v = i + k + len / 2;
                    double xr = re[v] * cr - im[v] * ci, xi = re[v] * ci + im[v] * cr;
                    re[v] = re[u] - xr; im[v] = im[u] - xi;
                    re[u] += xr; im[u] += xi;
                    double nr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = nr;
                }
            }
        }
    }

    static double Gauss(ref uint s)
    {
        double u1 = Rand(ref s), u2 = Rand(ref s);
        return Math.Sqrt(-2.0 * Math.Log(u1 + 1e-12)) * Math.Cos(2 * Math.PI * u2);
    }

    static double Rand(ref uint s)
    {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        return (s & 0xFFFFFF) / 16777216.0;
    }

    static double Smooth01(double x, double lo, double hi)
    {
        if (x <= lo) return 0;
        if (x >= hi) return 1;
        double t = (x - lo) / (hi - lo);
        return t * t * (3 - 2 * t);
    }

    static double[] Levinson(double[] r, int p)
    {
        double[] a = new double[p + 1];
        double[] tmp = new double[p + 1];
        a[0] = 1.0;
        double e = r[0];
        for (int i = 1; i <= p; i++)
        {
            double acc = r[i];
            for (int j = 1; j < i; j++) acc += a[j] * r[i - j];
            double k = -acc / e;
            for (int j = 1; j < i; j++) tmp[j] = a[j] + k * a[i - j];
            for (int j = 1; j < i; j++) a[j] = tmp[j];
            a[i] = k;
            e *= (1.0 - k * k);
            if (e <= 1e-30) break;
        }
        return a;
    }

    static float[] ProcessChannel(float[] x, int sr, DegrowlOptions o, string debugFile, out double wetFraction)
    {
        int N = x.Length;
        wetFraction = 0;
        float[] y = new float[N];
        if (N < 64) { Array.Copy(x, y, N); return y; }

        int H = Math.Max(1, (int)Math.Round(sr * 0.005));
        int W = (int)Math.Round(sr * 0.030); if ((W & 1) == 0) W++;
        int half = W / 2;
        int P = 2 + (int)Math.Round(sr / 1470.0);
        if (P < 12) P = 12; if (P > 48) P = 48;
        int M = N / H + 2;
        double pre = 0.97;

        double[] hann = new double[W];
        double hsum = 0;
        for (int i = 0; i < W; i++) { hann[i] = 0.5 - 0.5 * Math.Cos(2 * Math.PI * (i + 1) / (W + 1)); hsum += hann[i]; }

        double[] pe = new double[N];
        double[] xh = new double[N];
        double hpy = 0, hpx = 0;
        double hpA = Math.Exp(-2 * Math.PI * 60.0 / sr);
        for (int n = 0; n < N; n++)
        {
            pe[n] = x[n] - (n > 0 ? pre * x[n - 1] : 0.0);
            double v = x[n];
            hpy = hpA * (hpy + v - hpx); hpx = v;
            xh[n] = hpy;
        }

        double[][] rn = new double[M][];
        double[] pw = new double[M];
        for (int m = 0; m < M; m++)
        {
            int c0 = m * H - half;
            double[] seg = new double[W];
            double pe2 = 0;
            for (int i = 0; i < W; i++)
            {
                int n = c0 + i;
                if (n >= 0 && n < N) { seg[i] = pe[n] * hann[i]; double hv = xh[n]; pe2 += hann[i] * hv * hv; }
            }
            pw[m] = pe2 / hsum;
            double[] r = new double[P + 1];
            for (int j = 0; j <= P; j++)
            {
                double acc = 0;
                for (int i = j; i < W; i++) acc += seg[i] * seg[i - j];
                r[j] = acc;
            }
            if (r[0] > 1e-12) { double inv = 1.0 / r[0]; for (int j = 0; j <= P; j++) r[j] *= inv; }
            else { for (int j = 0; j <= P; j++) r[j] = 0; r[0] = 0; }
            rn[m] = r;
        }

        int NF = 1; while (NF < 2 * W) NF <<= 1;
        int NB = NF / 2 + 1;
        float[][] spec = new float[M][];
        {
            double[] fr = new double[NF];
            double[] fi = new double[NF];
            for (int m = 0; m < M; m++)
            {
                int c0 = m * H - half;
                Array.Clear(fr, 0, NF); Array.Clear(fi, 0, NF);
                for (int i = 0; i < W; i++)
                {
                    int n = c0 + i;
                    if (n >= 0 && n < N) fr[i] = x[n] * hann[i];
                }
                Fft(fr, fi);
                float[] sp2 = new float[NB];
                for (int b = 0; b < NB; b++) sp2[b] = (float)(fr[b] * fr[b] + fi[b] * fi[b]);
                spec[m] = sp2;
            }
        }
        double binHz = (double)sr / NF;
        double[] cum = new double[NB + 1];

        double f0 = o.F0;
        double org = Math.Max(0.0, Math.Min(1.0, o.Organic));
        uint rng = 2463534242u ^ (uint)(N * 2654435761u);
        double[] f0c = new double[M];
        {
            double drift = 0, jit = 0;
            double ad = Math.Exp(-0.005 / 0.12);
            double aj = Math.Exp(-0.005 / 0.02);
            for (int m = 0; m < M; m++)
            {
                drift = ad * drift + Math.Sqrt(1 - ad * ad) * Gauss(ref rng);
                jit = aj * jit + Math.Sqrt(1 - aj * aj) * Gauss(ref rng);
                f0c[m] = f0 * Math.Exp(org * (0.022 * drift + 0.006 * jit));
            }
        }
        int K = (int)Math.Floor(0.45 * sr / (f0 * 0.9));
        if (K < 1) K = 1;

        int G = 64;
        double fHf = Math.Min(4000.0, 0.4 * sr);
        double[,] gC = new double[G, P + 1];
        double[,] gS = new double[G, P + 1];
        double[] gPre = new double[G];
        bool[] gHigh = new bool[G];
        for (int g = 0; g < G; g++)
        {
            double fr = (g + 0.5) * (sr / 2.0) / G;
            double om = 2 * Math.PI * fr / sr;
            for (int j = 0; j <= P; j++) { gC[g, j] = Math.Cos(om * j); gS[g, j] = Math.Sin(om * j); }
            double dr = 1 - pre * Math.Cos(om), di = pre * Math.Sin(om);
            gPre[g] = 1.0 / (dr * dr + di * di);
            gHigh[g] = fr >= fHf;
        }

        double[] frameRe = new double[M * K];
        double[] frameIm = new double[M * K];
        double[] wetF = new double[M];
        double[] hfDbg = new double[M];
        int R = o.SmoothFrames;
        double[] tgt = new double[M];
        for (int m = 0; m < M; m++)
        {
            double s = 0, ws = 0;
            for (int d = -R; d <= R; d++)
            {
                int mm = m + d; if (mm < 0 || mm >= M) continue;
                double wt = R + 1 - Math.Abs(d);
                s += wt * pw[mm]; ws += wt;
            }
            tgt[m] = s / ws;
        }

        double[] rs = new double[P + 1];
        double[] lag = new double[P + 1];
        double lagBw = 60.0;
        for (int j = 0; j <= P; j++) { double t = 2 * Math.PI * lagBw * j / sr; lag[j] = Math.Exp(-0.5 * t * t); }

        for (int m = 0; m < M; m++)
        {
            for (int j = 0; j <= P; j++) rs[j] = 0;
            double ws = 0;
            for (int d = -R; d <= R; d++)
            {
                int mm = m + d; if (mm < 0 || mm >= M) continue;
                if (rn[mm][0] <= 0) continue;
                double wt = (R + 1 - Math.Abs(d));
                for (int j = 0; j <= P; j++) rs[j] += wt * rn[mm][j];
                ws += wt;
            }
            if (ws <= 0 || tgt[m] < 1e-14)
            {
                wetF[m] = 0;
                continue;
            }
            for (int j = 0; j <= P; j++) rs[j] = rs[j] / ws * lag[j];
            rs[0] *= 1.0 + 1e-4;
            double[] a = Levinson(rs, P);

            double totE = 0, hiE = 0;
            for (int g = 0; g < G; g++)
            {
                double re = 0, im = 0;
                for (int j = 0; j <= P; j++) { re += a[j] * gC[g, j]; im -= a[j] * gS[g, j]; }
                double pe_ = gPre[g] / (re * re + im * im + 1e-30);
                totE += pe_; if (gHigh[g]) hiE += pe_;
            }
            double hf = hiE / totE;
            hfDbg[m] = hf;
            wetF[m] = 1.0 - Smooth01(hf, o.HfLo, o.HfHi);

            cum[0] = 0;
            for (int b = 0; b < NB; b++)
            {
                double ssum = 0, wsum2 = 0;
                for (int d = -R; d <= R; d++)
                {
                    int mm = m + d; if (mm < 0 || mm >= M) continue;
                    double wt = R + 1 - Math.Abs(d);
                    ssum += wt * spec[mm][b]; wsum2 += wt;
                }
                cum[b + 1] = cum[b] + ssum / wsum2;
            }

            double sp = 0;
            int baseIdx = m * K;
            for (int k = 0; k < K; k++)
            {
                double fk = (k + 1) * f0c[m];
                if (fk > 0.45 * sr) { frameRe[baseIdx + k] = 0; frameIm[baseIdx + k] = 0; continue; }
                double om = 2 * Math.PI * fk / sr;
                double co = Math.Cos(om), si = Math.Sin(om);
                double c = 1.0, sn = 0.0;
                double re = 0, im = 0;
                for (int j = 0; j <= P; j++)
                {
                    re += a[j] * c; im -= a[j] * sn;
                    double nc = c * co - sn * si; sn = sn * co + c * si; c = nc;
                }
                double dr = 1 - pre * co, di = pre * si;
                double tr = re * dr - im * di;
                double ti = re * di + im * dr;
                double den = tr * tr + ti * ti + 1e-30;
                double hr = tr / den, hi = -ti / den;
                double hmag = Math.Sqrt(hr * hr + hi * hi) + 1e-30;
                double bw = Math.Max(o.EnvMinBwHz, o.EnvRelBw * fk);
                int bLo = (int)Math.Floor((fk - bw) / binHz); if (bLo < 0) bLo = 0;
                int bHi = (int)Math.Ceiling((fk + bw) / binHz); if (bHi > NB - 1) bHi = NB - 1;
                double meas = (cum[bHi + 1] - cum[bLo]) / (bHi - bLo + 1);
                double amp = Math.Sqrt(meas + 1e-30);
                hr = amp * hr / hmag; hi = amp * hi / hmag;
                frameRe[baseIdx + k] = hr; frameIm[baseIdx + k] = hi;
                sp += 0.5 * (hr * hr + hi * hi);
            }
            double gain = Math.Sqrt(tgt[m] / (sp + 1e-30));
            for (int k = 0; k < K; k++) { frameRe[baseIdx + k] *= gain; frameIm[baseIdx + k] *= gain; }
        }

        if (org > 0)
        {
            double[] phi = new double[K];
            for (int m = 0; m < M; m++)
            {
                for (int k = 0; k < K; k++)
                {
                    double fk = (k + 1) * f0;
                    double sig = org * 0.45 * Math.Min(1.0, fk / 2000.0);
                    phi[k] = 0.90 * phi[k] + sig * Gauss(ref rng);
                    int idx = m * K + k;
                    double cr = Math.Cos(phi[k]), ci = Math.Sin(phi[k]);
                    double re = frameRe[idx], im = frameIm[idx];
                    frameRe[idx] = re * cr - im * ci; frameIm[idx] = re * ci + im * cr;
                }
            }
        }

        double[] wetS = new double[M];
        for (int m = 0; m < M; m++)
        {
            double s = 0, ws = 0;
            for (int d = -2; d <= 2; d++)
            {
                int mm = m + d; if (mm < 0 || mm >= M) continue;
                double wt = 3 - Math.Abs(d); s += wt * wetF[mm]; ws += wt;
            }
            wetS[m] = s / ws;
        }

        double[] syn = new double[N];
        double[] zr = new double[K];
        double[] zi = new double[K];
        double[] rr = new double[K];
        double[] ri = new double[K];
        double theta = 0;
        for (int m = 0; m + 1 < M; m++)
        {
            int n0 = m * H;
            if (n0 >= N) break;
            int n1 = Math.Min(N, n0 + H);
            double om = 2 * Math.PI * f0c[m] / sr;
            for (int k = 0; k < K; k++)
            {
                double ph = ((k + 1) * theta) % (2 * Math.PI);
                zr[k] = Math.Cos(ph); zi[k] = Math.Sin(ph);
                rr[k] = Math.Cos(om * (k + 1)); ri[k] = Math.Sin(om * (k + 1));
            }
            theta = (theta + om * (n1 - n0)) % (2 * Math.PI);
            if (wetS[m] <= 0 && wetS[m + 1] <= 0) continue;
            int b0 = m * K, b1 = (m + 1) * K;
            for (int n = n0; n < n1; n++)
            {
                double t = (double)(n - n0) / H;
                double acc = 0;
                for (int k = 0; k < K; k++)
                {
                    double cr = frameRe[b0 + k] + t * (frameRe[b1 + k] - frameRe[b0 + k]);
                    double ci = frameIm[b0 + k] + t * (frameIm[b1 + k] - frameIm[b0 + k]);
                    acc += cr * zr[k] - ci * zi[k];
                    double nr = zr[k] * rr[k] - zi[k] * ri[k];
                    double ni = zr[k] * ri[k] + zi[k] * rr[k];
                    zr[k] = nr; zi[k] = ni;
                }
                syn[n] = acc;
            }
        }

        double[] air = new double[N];
        if (org > 0)
        {
            double fc = Math.Min(3000.0, 0.3 * sr);
            double wc = Math.Tan(Math.PI * fc / sr);
            double q = 1.0 / Math.Sqrt(2.0);
            double nrm = 1.0 / (1 + wc / q + wc * wc);
            double b0h = nrm, b1h = -2 * nrm, b2h = nrm;
            double a1h = 2 * (wc * wc - 1) * nrm, a2h = (1 - wc / q + wc * wc) * nrm;
            double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
            for (int n = 0; n < N; n++)
            {
                double xv = x[n];
                double yv = b0h * xv + b1h * x1 + b2h * x2 - a1h * y1 - a2h * y2;
                x2 = x1; x1 = xv; y2 = y1; y1 = yv;
                air[n] = yv;
            }
        }
        double airAmt = 0.65 * org;

        double synScale = Math.Sqrt(Math.Max(0.0, 1.0 - o.Leak * o.Leak));
        double wsum = 0;
        for (int n = 0; n < N; n++)
        {
            int m = n / H; double t = (double)(n - m * H) / H;
            double wv = wetS[m] + t * ((m + 1 < M ? wetS[m + 1] : wetS[m]) - wetS[m]);
            wsum += wv;
            double wet = synScale * syn[n] + o.Leak * x[n] + airAmt * air[n];
            y[n] = (float)((1 - wv) * x[n] + wv * wet);
        }
        wetFraction = wsum / N;

        if (debugFile != null)
        {
            using (StreamWriter sw = new StreamWriter(debugFile))
                for (int m = 0; m < M; m++) sw.WriteLine("{0}\t{1:F4}\t{2:F4}\t{3:E3}", m * H * 1000.0 / sr, hfDbg[m], wetS[m], tgt[m]);
        }
        return y;
    }

    static void Limit(float[][] d, double ceiling)
    {
        int ch = d.Length, N = d[0].Length;
        double[] need = new double[N];
        bool any = false;
        for (int n = 0; n < N; n++)
        {
            double pk = 0;
            for (int c = 0; c < ch; c++) { double a = Math.Abs(d[c][n]); if (a > pk) pk = a; }
            need[n] = pk > ceiling ? ceiling / pk : 1.0;
            if (pk > ceiling) any = true;
        }
        if (!any) return;
        int L = 128;
        double[] mn = new double[N];
        for (int n = 0; n < N; n++)
        {
            double v = 1.0;
            int a0 = Math.Max(0, n - L), a1 = Math.Min(N - 1, n + L);
            for (int i = a0; i <= a1; i++) if (need[i] < v) v = need[i];
            mn[n] = v;
        }
        double[] g = new double[N];
        for (int n = 0; n < N; n++)
        {
            double s = 0; int cnt = 0;
            int a0 = Math.Max(0, n - L), a1 = Math.Min(N - 1, n + L);
            for (int i = a0; i <= a1; i++) { s += mn[i]; cnt++; }
            g[n] = s / cnt;
        }
        for (int c = 0; c < ch; c++)
            for (int n = 0; n < N; n++) d[c][n] = (float)(d[c][n] * g[n]);
    }
}

public class OtoParams
{
    public double Offset, Consonant, Cutoff, Preutterance, Overlap;
    public string Kind = "";
}

public static class OtoGen
{
    // Embedded Default Oto.ini Template in ANSI (Shift-JIS / CP932)
    public static string DefaultOtoContent = 
        "あ.wav=,220.0,360.0,688.049,40.0,0.0\r\n" +
        "い.wav=,200.0,399.999,327.8,39.999,0.0\r\n" +
        "う.wav=,220.0,100.0,688.049,40.0,0.0\r\n" +
        "え.wav=,200.0,99.999,547.8,39.999,0.0\r\n" +
        "お.wav=,220.0,580.0,372.698,40.0,0.0\r\n" +
        "か.wav=,220.0,100.0,686.53,19.999,0.0\r\n" +
        "が.wav=,100.0,100.0,581.428,60.0,0.0\r\n" +
        "き.wav=,200.0,99.999,615.6,39.999,0.0\r\n" +
        "き2.wav=,200.0,500.0,615.6,39.999,0.0\r\n" +
        "きゃ.wav=,120.0,100.0,727.573,40.0,0.0\r\n" +
        "きゅ.wav=,160.0,540.0,307.573,19.999,0.0\r\n" +
        "きょ.wav=,140.0,580.0,679.773,99.999,0.0\r\n" +
        "ぎ.wav=,160.0,580.0,650.952,40.0,0.0\r\n" +
        "ぎゃ.wav=,160.0,540.0,645.941,40.0,0.0\r\n" +
        "ぎゅ.wav=,160.0,540.0,647.573,40.0,0.0\r\n" +
        "ぎょ.wav=,160.0,100.0,799.773,40.0,0.0\r\n" +
        "く.wav=,200.0,500.0,615.6,39.999,0.0\r\n" +
        "ぐ.wav=,180.0,560.0,650.952,40.0,0.0\r\n" +
        "ぐぁ.wav=,220.0,500.0,531.972,19.999,0.0\r\n" +
        "ぐぃ.wav=,200.0,99.999,199.977,39.999,0.0\r\n" +
        "ぐぇ.wav=,220.0,100.0,546.643,19.999,0.0\r\n" +
        "ぐぉ.wav=,220.0,100.0,626.643,19.999,0.0\r\n" +
        "け.wav=,200.0,500.0,615.6,39.999,0.0\r\n" +
        "げ.wav=,160.0,100.0,650.952,40.0,0.0\r\n" +
        "こ.wav=,200.0,659.999,787.8,39.999,0.0\r\n" +
        "ご.wav=,140.0,560.0,612.811,79.999,0.0\r\n" +
        "さ.wav=,20.0,279.999,650.589,39.999,0.0\r\n" +
        "ざ.wav=,80.0,600.0,723.151,39.999,0.0\r\n" +
        "し.wav=,40.0,100.0,650.589,0.0,0.0\r\n" +
        "しゃ.wav=,20.0,99.999,697.392,0.0,0.0\r\n" +
        "しゅ.wav=,20.0,99.999,697.392,0.0,0.0\r\n" +
        "しょ.wav=,20.0,660.0,818.004,260.0,0.0\r\n" +
        "じ.wav=,100.0,100.0,715.419,40.0,0.0\r\n" +
        "じゃ.wav=,120.0,140.0,635.532,120.0,0.0\r\n" +
        "じゅ.wav=,120.0,560.0,496.235,40.0,0.0\r\n" +
        "じょ.wav=,100.0,400.0,807.482,40.0,0.0\r\n" +
        "す.wav=,20.0,660.0,763.287,60.0,0.0\r\n" +
        "ず.wav=,120.0,100.0,655.419,40.0,0.0\r\n" +
        "せ.wav=,20.0,559.999,778.934,39.999,0.0\r\n" +
        "ぜ.wav=,100.0,100.0,735.419,0.0,0.0\r\n" +
        "そ.wav=,0.0,820.0,859.795,40.0,0.0\r\n" +
        "ぞ.wav=,100.0,100.0,751.859,40.0,0.0\r\n" +
        "た.wav=,220.0,100.0,533.061,19.999,0.0\r\n" +
        "だ.wav=,200.0,99.999,489.07,19.999,0.0\r\n" +
        "ち.wav=,40.0,100.0,583.378,0.0,0.0\r\n" +
        "ち2.wav=,80.0,99.999,658.049,0.0,0.0\r\n" +
        "ちゃ.wav=,100.0,100.0,550.022,0.0,0.0\r\n" +
        "ちゅ.wav=,100.0,520.0,570.022,160.0,0.0\r\n" +
        "ちょ.wav=,100.0,640.0,561.428,139.999,0.0\r\n" +
        "つ.wav=,180.0,560.0,637.233,120.0,0.0\r\n" +
        "つぁ.wav=,120.0,500.0,550.022,120.0,0.0\r\n" +
        "つぃ.wav=,140.0,99.999,562.335,0.0,0.0\r\n" +
        "つぇ.wav=,160.0,559.999,631.609,120.0,0.0\r\n" +
        "つぉ.wav=,160.0,600.0,701.428,40.0,0.0\r\n" +
        "て.wav=,200.0,540.0,677.233,39.999,0.0\r\n" +
        "てぃ.wav=,220.0,100.0,426.553,19.999,0.0\r\n" +
        "てゅ.wav=,220.0,100.0,708.73,19.999,0.0\r\n" +
        "てゅ2.wav=,220.0,540.0,647.256,19.999,0.0\r\n" +
        "で.wav=,200.0,99.999,555.986,39.999,0.0\r\n" +
        "でぃ.wav=,220.0,100.0,608.73,19.999,0.0\r\n" +
        "でゅ.wav=,200.0,580.0,267.256,19.999,0.0\r\n" +
        "と.wav=,200.0,679.999,767.8,19.999,0.0\r\n" +
        "とぅ.wav=,200.0,560.0,747.256,19.999,0.0\r\n" +
        "ど.wav=,180.0,500.0,687.482,40.0,0.0\r\n" +
        "どぅ.wav=,200.0,560.0,739.682,19.999,0.0\r\n" +
        "な.wav=,120.0,120.0,603.628,120.0,0.0\r\n" +
        "に.wav=,120.0,100.0,603.628,100.0,0.0\r\n" +
        "にゃ.wav=,160.0,100.0,588.526,60.0,0.0\r\n" +
        "にゅ.wav=,200.0,540.0,540.498,39.999,0.0\r\n" +
        "にょ.wav=,160.0,660.0,683.129,60.0,0.0\r\n" +
        "ぬ.wav=,140.0,660.0,745.941,79.999,0.0\r\n" +
        "ね.wav=,100.0,640.0,665.941,120.0,0.0\r\n" +
        "の.wav=,180.0,100.0,696.235,40.0,0.0\r\n" +
        "は.wav=,140.0,540.0,660.634,39.999,0.0\r\n" +
        "ば.wav=,220.0,500.0,489.07,19.999,0.0\r\n" +
        "ぱ.wav=,200.0,99.999,564.24,19.999,0.0\r\n" +
        "ひ.wav=,160.0,100.0,660.634,60.0,0.0\r\n" +
        "ひゃ.wav=,80.0,219.999,568.526,60.0,0.0\r\n" +
        "ひゅ.wav=,40.0,100.0,820.498,60.0,0.0\r\n" +
        "ひょ.wav=,100.0,800.0,854.829,180.0,0.0\r\n" +
        "び.wav=,220.0,100.0,486.961,40.0,0.0\r\n" +
        "びゃ.wav=,220.0,500.0,606.349,19.999,0.0\r\n" +
        "びゅ.wav=,220.0,440.0,381.541,19.999,0.0\r\n" +
        "びょ.wav=,220.0,500.0,727.165,19.999,0.0\r\n" +
        "ぴ.wav=,220.0,500.0,564.24,19.999,0.0\r\n" +
        "ぴゃ.wav=,220.0,100.0,568.231,19.999,0.0\r\n" +
        "ぴゅ.wav=,220.0,520.0,361.541,40.0,0.0\r\n" +
        "ぴょ.wav=,240.0,420.0,483.242,20.0,0.0\r\n" +
        "ふ.wav=,160.0,419.999,700.521,60.0,0.0\r\n" +
        "ふぁ.wav=,220.0,100.0,566.621,40.0,0.0\r\n" +
        "ふぃ.wav=,200.0,99.999,566.621,39.999,0.0\r\n" +
        "ふぇ.wav=,220.0,500.0,622.426,40.0,0.0\r\n" +
        "ふぉ.wav=,220.0,540.0,700.521,40.0,0.0\r\n" +
        "ぶ.wav=,220.0,660.0,784.671,40.0,0.0\r\n" +
        "ぷ.wav=,220.0,500.0,527.165,19.999,0.0\r\n" +
        "へ.wav=,160.0,580.0,460.521,40.0,0.0\r\n" +
        "べ.wav=,240.0,100.0,667.482,20.0,0.0\r\n" +
        "ぺ.wav=,220.0,100.0,507.165,40.0,0.0\r\n" +
        "ほ.wav=,180.0,580.0,700.521,40.0,0.0\r\n" +
        "ぼ.wav=,240.0,480.0,604.671,20.0,0.0\r\n" +
        "ぽ.wav=,220.0,600.0,715.963,19.999,0.0\r\n" +
        "ま.wav=,160.0,580.0,791.451,79.999,0.0\r\n" +
        "み.wav=,120.0,620.0,791.451,120.0,0.0\r\n" +
        "みゃ.wav=,180.0,100.0,702.176,80.0,0.0\r\n" +
        "みゅ.wav=,220.0,400.0,702.176,40.0,0.0\r\n" +
        "みょ.wav=,200.0,560.0,612.471,60.0,0.0\r\n" +
        "む.wav=,220.0,520.0,571.451,19.999,0.0\r\n" +
        "め.wav=,100.0,120.0,691.451,120.0,0.0\r\n" +
        "も.wav=,100.0,680.0,830.612,160.0,0.0\r\n" +
        "や.wav=,100.0,540.0,746.734,40.0,0.0\r\n" +
        "ゆ.wav=,80.0,99.999,746.734,80.0,0.0\r\n" +
        "よ.wav=,60.0,140.0,762.811,60.0,0.0\r\n" +
        "ら.wav=,120.0,100.0,746.734,40.0,0.0\r\n" +
        "り.wav=,100.0,100.0,717.732,100.0,0.0\r\n" +
        "りゃ.wav=,200.0,99.999,566.439,39.999,0.0\r\n" +
        "りゅ.wav=,220.0,100.0,652.517,40.0,0.0\r\n" +
        "りょ.wav=,260.0,99.999,670.521,39.999,0.0\r\n" +
        "る.wav=,220.0,100.0,778.185,79.999,0.0\r\n" +
        "れ.wav=,220.0,100.0,698.185,60.0,0.0\r\n" +
        "ろ.wav=,220.0,620.0,892.335,60.0,0.0\r\n" +
        "わ.wav=,180.0,560.0,710.181,100.0,0.0\r\n" +
        "を.wav=,200.0,120.0,624.353,80.0,0.0\r\n" +
        "ん.wav=,200.0,99.999,704.353,39.999,0.0\r\n" +
        "息1.wav=,120.0,100.0,60.793,100.0,0.0\r\n" +
        "息2.wav=,60.0,200.0,110.566,200.0,0.0\r\n" +
        "息3.wav=,40.0,100.0,70.136,100.0,0.0\r\n" +
        "息4.wav=,60.0,100.0,94.897,100.0,0.0\r\n" +
        "息5.wav=,0.0,80.0,39.342,80.0,0.0";

    static Encoding DetectEncoding(byte[] b, out int preamble)
    {
        preamble = 0;
        if (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) { preamble = 3; return new UTF8Encoding(false); }
        if (b.Length >= 2 && b[0] == 0xFF && b[1] == 0xFE) { preamble = 2; return new UnicodeEncoding(false, false); }
        if (b.Length >= 2 && b[0] == 0xFE && b[1] == 0xFF) { preamble = 2; return new UnicodeEncoding(true, false); }
        return Encoding.GetEncoding(932);
    }

    public static string Regenerate(string oldOtoPath, string wavDir, string newOtoPath, string reportPath)
    {
        Encoding enc = Encoding.GetEncoding(932);
        string text = "";
        int pre = 0;
        bool hadOld = false;

        if (oldOtoPath != null && File.Exists(oldOtoPath))
        {
            byte[] raw = File.ReadAllBytes(oldOtoPath);
            enc = DetectEncoding(raw, out pre);
            text = enc.GetString(raw, pre, raw.Length - pre);
            hadOld = true;
        }
        else
        {
            text = DefaultOtoContent;
        }

        byte[] body = enc.GetBytes(text);
        byte[] bom = new byte[pre];
        if (pre > 0 && oldOtoPath != null) { byte[] raw2 = File.ReadAllBytes(oldOtoPath); Array.Copy(raw2, bom, pre); }
        byte[] all = new byte[bom.Length + body.Length];
        Array.Copy(bom, 0, all, 0, bom.Length);
        Array.Copy(body, 0, all, bom.Length, body.Length);
        File.WriteAllBytes(newOtoPath, all);

        if (reportPath != null) File.WriteAllText(reportPath, "Generated oto.ini using embedded default template in ANSI (Shift-JIS/CP932).\r\n", new UTF8Encoding(true));
        return hadOld ? "oto.ini preserved/updated in ANSI" : "Embedded default oto.ini created in ANSI (Shift-JIS/CP932)";
    }
}
'@

# ---------------------------------------------------------------- helpers
function Write-Info([string]$Text) { Write-Host $Text }
function Write-Warn([string]$Text) { Write-Host ('  ! ' + $Text) -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host ('  X ' + $Text) -ForegroundColor Red }
function Write-Good([string]$Text) { Write-Host ('  OK ' + $Text) -ForegroundColor Green }

function Exit-Tool([int]$Code) {
    if ($script:WorkDir -ne '' -and (Test-Path -LiteralPath $script:WorkDir)) {
        try { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    if (-not $NoPause) {
        Write-Host ''
        [void](Read-Host 'Press Enter to close')
    }
    exit $Code
}

function Get-DialogOwner {
    Add-Type -AssemblyName System.Windows.Forms
    $f = New-Object System.Windows.Forms.Form
    $f.TopMost = $true
    $f.ShowInTaskbar = $false
    $f.StartPosition = 'CenterScreen'
    $f.Opacity = 0
    $f.Show()
    return $f
}

function Select-Folder([string]$Description) {
    Add-Type -AssemblyName System.Windows.Forms
    $owner = Get-DialogOwner
    try {
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = $Description
        $d.ShowNewFolderButton = $false
        if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
        return $null
    } finally { $owner.Close(); $owner.Dispose() }
}

function Select-File([string]$Title, [string]$Filter, [string]$InitialDir) {
    Add-Type -AssemblyName System.Windows.Forms
    $owner = Get-DialogOwner
    try {
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Title = $Title
        $d.Filter = $Filter
        $d.CheckFileExists = $true
        $d.Multiselect = $false
        if ($InitialDir -ne '' -and (Test-Path -LiteralPath $InitialDir)) { $d.InitialDirectory = $InitialDir }
        if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $d.FileName }
        return $null
    } finally { $owner.Close(); $owner.Dispose() }
}

function ConvertTo-ArgString([string]$a) {
    if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
    $s = $a -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

function Invoke-Ffmpeg([string]$Exe, [string[]]$FfArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($FfArgs | ForEach-Object { ConvertTo-ArgString $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $err = $errTask.Result
    $errLines = @(($err -split "`r?`n") | Where-Object { $_.Trim() -ne '' })
    $errShort = ''
    if ($errLines.Count -gt 0) { $errShort = $errLines[0].Trim() -replace '^\[[^\]]*\]\s*', '' }
    return New-Object PSObject -Property @{ ExitCode = $p.ExitCode; Out = $out; Err = $errShort }
}

function Read-Info([string]$WavPath) {
    $parts = ([Degrowl]::Describe($WavPath)) -split ';'
    return New-Object PSObject -Property @{
        Codec = $parts[0]; Rate = [int]$parts[1]; Channels = [int]$parts[2]; Frames = [int]$parts[3]
    }
}

function Test-FfmpegExe([string]$Exe) {
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "ffmpeg not found: $Exe" }
    $r = Invoke-Ffmpeg $Exe @('-hide_banner', '-version')
    if ($r.ExitCode -ne 0 -or $r.Out -notmatch 'ffmpeg version') {
        throw 'The selected file does not behave like ffmpeg (-version failed).'
    }
    $version = ($r.Out -split "`n")[0].Trim()
    $t = Join-Path $script:WorkDir 'pf_in.wav'
    $a = Join-Path $script:WorkDir 'pf_a.wav'
    $c = Join-Path $script:WorkDir 'pf_c.wav'
    [Degrowl]::WriteTestTone($t)
    $r1 = Invoke-Ffmpeg $Exe @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-i', $t, '-c:a', 'pcm_f32le', '-f', 'wav', $a)
    if ($r1.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $a)) { throw ('ffmpeg could not decode a test WAV: ' + $r1.Err) }
    $r2 = Invoke-Ffmpeg $Exe @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-i', $a, '-map_metadata', '-1', '-c:a', 'pcm_s16le', '-fflags', '+bitexact', '-flags:a', '+bitexact', '-f', 'wav', $c)
    if ($r2.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $c)) { throw ('ffmpeg could not encode a test WAV: ' + $r2.Err) }
    $i = Read-Info $c
    if ($i.Codec -ne 'pcm_s16le' -or $i.Frames -ne 4410) { throw 'ffmpeg round-trip test produced an unexpected file.' }
    return $version
}

function Get-StrengthSettings([string]$Name) {
    switch ($Name) {
        'Light'     { return New-Object PSObject -Property @{ Name = 'Light';      Leak = 0.5; Organic = $Organic } }
        'Balanced'  { return New-Object PSObject -Property @{ Name = 'Balanced';   Leak = 0.3; Organic = $Organic } }
        'CleanPlus' { return New-Object PSObject -Property @{ Name = 'Clean+';     Leak = 0.0; Organic = 1.0 } }
        'Flat'      { return New-Object PSObject -Property @{ Name = 'Flat';       Leak = 0.0; Organic = 0.0 } }
        default     { return New-Object PSObject -Property @{ Name = 'Clean';      Leak = 0.0; Organic = $Organic } }
    }
}

function New-Options([object]$Settings) {
    $o = New-Object DegrowlOptions
    $o.F0 = $Pitch
    $o.Leak = $Settings.Leak
    $o.Organic = $Settings.Organic
    return $o
}

function Convert-OneWav([string]$Ff, [string]$Src, [string]$Dst, [object]$Opt) {
    $w = $script:WorkDir
    $inW = Join-Path $w 'in.wav'
    $aW = Join-Path $w 'a.wav'
    $bW = Join-Path $w 'b.wav'
    $cW = Join-Path $w 'c.wav'
    foreach ($f in @($inW, $aW, $bW, $cW)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    [System.IO.File]::Copy($Src, $inW, $true)

    $codec = 'pcm_s16le'
    try { $ci = Read-Info $inW; if ($ci.Codec -ne 'unknown') { $codec = $ci.Codec } } catch { }

    $r = Invoke-Ffmpeg $Ff @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-i', $inW, '-map_metadata', '-1', '-c:a', 'pcm_f32le', '-f', 'wav', $aW)
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $aW)) { throw ('ffmpeg decode failed: ' + $r.Err) }
    $ai = Read-Info $aW

    $summary = [Degrowl]::Process($aW, $bW, $Opt)

    $r = Invoke-Ffmpeg $Ff @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-i', $bW, '-map_metadata', '-1', '-c:a', $codec, '-fflags', '+bitexact', '-flags:a', '+bitexact', '-f', 'wav', $cW)
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $cW)) { throw ('ffmpeg encode failed: ' + $r.Err) }
    $ci2 = Read-Info $cW
    if ($ci2.Rate -ne $ai.Rate -or $ci2.Channels -ne $ai.Channels -or $ci2.Frames -ne $ai.Frames) {
        throw ('output format mismatch (rate/channels/length) - expected {0}/{1}/{2}, got {3}/{4}/{5}' -f $ai.Rate, $ai.Channels, $ai.Frames, $ci2.Rate, $ci2.Channels, $ci2.Frames)
    }
    $dir = [System.IO.Path]::GetDirectoryName($Dst)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::Copy($cW, $Dst, $true)
    return ($summary + ' ' + $codec)
}

function Initialize-Encodings {
    try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
}

function Update-CharacterTxt([string]$Path) {
    Initialize-Encodings
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $n = $bytes.Length
    $encName = ''
    $preamble = 0
    $enc = $null
    $strictFallbackE = New-Object System.Text.EncoderExceptionFallback
    $strictFallbackD = New-Object System.Text.DecoderExceptionFallback
    if ($n -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        $encName = 'UTF-32 LE (BOM)'; $preamble = 4; $enc = [System.Text.Encoding]::GetEncoding('utf-32', $strictFallbackE, $strictFallbackD)
    } elseif ($n -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encName = 'UTF-32 BE (BOM)'; $preamble = 4; $enc = [System.Text.Encoding]::GetEncoding('utf-32BE', $strictFallbackE, $strictFallbackD)
    } elseif ($n -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encName = 'UTF-8 (BOM)'; $preamble = 3; $enc = New-Object System.Text.UTF8Encoding($false, $true)
    } elseif ($n -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encName = 'UTF-16 LE (BOM)'; $preamble = 2; $enc = New-Object System.Text.UnicodeEncoding($false, $false, $true)
    } elseif ($n -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encName = 'UTF-16 BE (BOM)'; $preamble = 2; $enc = New-Object System.Text.UnicodeEncoding($true, $false, $true)
    } elseif ($n -ge 4 -and $bytes[1] -eq 0 -and $bytes[0] -ne 0 -and $bytes[3] -eq 0) {
        $encName = 'UTF-16 LE (no BOM)'; $enc = New-Object System.Text.UnicodeEncoding($false, $false, $true)
    } elseif ($n -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -ne 0 -and $bytes[2] -eq 0) {
        $encName = 'UTF-16 BE (no BOM)'; $enc = New-Object System.Text.UnicodeEncoding($true, $false, $true)
    } else {
        $hasHigh = $false
        foreach ($b in $bytes) { if ($b -ge 0x80) { $hasHigh = $true; break } }
        $u8 = New-Object System.Text.UTF8Encoding($false, $true)
        $isUtf8 = $true
        try { [void]$u8.GetString($bytes) } catch { $isUtf8 = $false }
        if ($hasHigh -and $isUtf8) { $encName = 'UTF-8 (no BOM)'; $enc = $u8 }
        else {
            try { $enc = [System.Text.Encoding]::GetEncoding(932, $strictFallbackE, $strictFallbackD); $encName = 'CP932 / Shift-JIS' }
            catch { return 'SKIPPED: this system cannot decode CP932; file left unchanged.' }
        }
    }

    $bodyLen = $n - $preamble
    $body = New-Object byte[] $bodyLen
    [System.Array]::Copy($bytes, $preamble, $body, 0, $bodyLen)
    try { $text = $enc.GetString($body) } catch { return ('SKIPPED: could not decode character.txt as ' + $encName + '; file left unchanged.') }

    $back = $enc.GetBytes($text)
    $same = ($back.Length -eq $body.Length)
    if ($same) { for ($i = 0; $i -lt $back.Length; $i++) { if ($back[$i] -ne $body[$i]) { $same = $false; break } } }
    if (-not $same) { return ('SKIPPED: ' + $encName + ' text does not round-trip exactly; file left unchanged.') }

    $m = [regex]::Match($text, '(?im)^(?<pre>[ \t]*name[ \t]*=)(?<val>[^\r\n]*)')
    if (-not $m.Success) { return 'SKIPPED: no "name=" line found; file left unchanged.' }
    $val = $m.Groups['val'].Value
    if ($val.Contains($script:Marker)) { return ('already marked (' + $encName + ')') }
    $newText = $text.Substring(0, $m.Groups['val'].Index) + $val + $script:Marker + $text.Substring($m.Groups['val'].Index + $val.Length)
    try { $newBody = $enc.GetBytes($newText) } catch { return ('SKIPPED: the marker cannot be stored in ' + $encName + '; file left unchanged.') }
    $outBytes = New-Object byte[] ($preamble + $newBody.Length)
    if ($preamble -gt 0) { [System.Array]::Copy($bytes, 0, $outBytes, 0, $preamble) }
    [System.Array]::Copy($newBody, 0, $outBytes, $preamble, $newBody.Length)
    [System.IO.File]::WriteAllBytes($Path, $outBytes)
    return ('updated (' + $encName + ')')
}

function Update-OtoFiles([string]$Root, [string]$ReportBase) {
    Initialize-Encodings
    $found = @([System.IO.Directory]::GetFiles($Root, '*', [System.IO.SearchOption]::AllDirectories) | Where-Object { [System.IO.Path]::GetFileName($_).ToLowerInvariant() -eq 'oto.ini' })
    $results = New-Object System.Collections.ArrayList
    $targets = New-Object System.Collections.ArrayList
    foreach ($f in $found) { [void]$targets.Add($f) }
    if ($targets.Count -eq 0) { [void]$targets.Add((Join-Path $Root 'oto.ini')) }
    $n = 0
    foreach ($t in $targets) {
        $n++
        $dir = [System.IO.Path]::GetDirectoryName($t)
        $old = $null
        if ([System.IO.File]::Exists($t)) {
            $backup = Join-Path $dir 'oto_before_regeneration.ini'
            if ([System.IO.File]::Exists($backup)) { $backup = Join-Path $dir ('oto_before_regeneration_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.ini') }
            [System.IO.File]::Copy($t, $backup, $false)
            $old = $backup
        }
        $tmp = Join-Path $script:WorkDir ('oto_new_' + $n + '.ini')
        $rep = $ReportBase + '_oto_report' + $(if ($n -gt 1) { '_' + $n } else { '' }) + '.txt'
        try {
            $sum = [OtoGen]::Regenerate($old, $dir, $tmp, $rep)
            [System.IO.File]::Copy($tmp, $t, $true)
            [void]$results.Add(($t.Substring($Root.Length).TrimStart('\', '/') + ': ' + $sum))
        } catch {
            [void]$results.Add(($t.Substring($Root.Length).TrimStart('\', '/') + ': FAILED - ' + $_.Exception.Message + ' (old oto.ini left in place)'))
        }
    }
    return $results
}

try {
    Write-Host ''
    Write-Host ('=== ' + $script:ToolName + ' ===') -ForegroundColor Cyan
    Write-Host 'Creates a processed COPY of your own voicebank. Your original is never touched.'
    Write-Host ''

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('HakaineDegrowl_' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:WorkDir)
    Add-Type -TypeDefinition $csharp -Language CSharp

    if ($SourceBank -eq '') {
        Write-Info 'Step 1: choose your Hakaine Maiko voicebank folder.'
        $SourceBank = Select-Folder 'Select your voicebank folder (containing the WAV files)'
        if (-not $SourceBank) { Write-Info 'Cancelled - nothing was changed.'; Exit-Tool 0 }
    }
    $src = $SourceBank.TrimEnd('\', '/')
    if (-not [System.IO.Directory]::Exists($src)) { throw "Voicebank folder not found: $src" }
    $src = [System.IO.Path]::GetFullPath($src).TrimEnd('\', '/')
    $parent = [System.IO.Path]::GetDirectoryName($src)
    if (-not $parent) { throw 'Please choose a voicebank folder, not a whole drive.' }
    $leaf = [System.IO.Path]::GetFileName($src)
    $dstRoot = Join-Path $parent ($leaf + '_degrowled')

    $allFiles = [System.IO.Directory]::GetFiles($src, '*', [System.IO.SearchOption]::AllDirectories)
    $wavs = @($allFiles | Where-Object { $_.ToLowerInvariant().EndsWith('.wav') } | Sort-Object)
    if ($wavs.Count -eq 0) { throw 'No .wav files were found in that folder.' }
    Write-Good ("Voicebank: $src")
    Write-Info ("      {0} WAV files found." -f $wavs.Count)

    if ($Mode -eq 'Oto') { $FfmpegPath = 'n/a' }
    if ($FfmpegPath -eq '') {
        Write-Info ''
        Write-Info 'Step 2: choose your portable ffmpeg.exe.'
        $FfmpegPath = Select-File 'Select ffmpeg.exe (portable build)' 'ffmpeg.exe|ffmpeg.exe|Programs (*.exe)|*.exe' ''
        if (-not $FfmpegPath) { Write-Info 'Cancelled - nothing was changed.'; Exit-Tool 0 }
    }
    $ff = ''; $ver = 'not used'
    if ($Mode -ne 'Oto') {
        $ff = [System.IO.Path]::GetFullPath($FfmpegPath)
        try { $ver = Test-FfmpegExe $ff }
        catch { throw ('The selected file is not a working ffmpeg: ' + $_.Exception.Message) }
        Write-Good ('ffmpeg works: ' + $ver)
    }

    if ($Mode -eq 'Ask') {
        Write-Info ''
        Write-Info 'What would you like to do?'
        Write-Info '  1) Test ONE sample first and compare Light / Balanced / Clean (recommended)'
        Write-Info '  2) Process the whole voicebank (also creates/updates oto.ini in ANSI)'
        Write-Info '  3) Only create/rebuild oto.ini of a bank that is ALREADY processed'
        Write-Info '  Q) Quit'
        $ans = (Read-Host 'Choose 1, 2, 3 or Q').Trim().ToUpperInvariant()
        if ($ans -eq '1') { $Mode = 'Test' } elseif ($ans -eq '2') { $Mode = 'Bank' } elseif ($ans -eq '3') { $Mode = 'Oto' } else { Write-Info 'Nothing was changed.'; Exit-Tool 0 }
    }

    if ($Mode -eq 'Oto') {
        Write-Info ''
        Write-Info 'This creates or updates oto.ini inside the folder you chose in ANSI (Shift-JIS).'
        if (-not $Yes) {
            $ok = (Read-Host 'Continue? (Y/N)').Trim().ToUpperInvariant()
            if ($ok -ne 'Y' -and $ok -ne 'YES') { Write-Info 'Cancelled - nothing was changed.'; Exit-Tool 0 }
        }
        $res = Update-OtoFiles $src $src
        Write-Info ''
        foreach ($r in $res) { Write-Info ('oto.ini -> ' + $r) }
        Exit-Tool 0
    }

    if ($Mode -eq 'Test') {
        if ($TestFile -eq '') {
            Write-Info ''
            Write-Info 'Choose one WAV from the voicebank to test.'
            $TestFile = Select-File 'Select one voicebank WAV to test' 'WAV files (*.wav)|*.wav' $src
            if (-not $TestFile) { Write-Info 'Cancelled - nothing was changed.'; Exit-Tool 0 }
        }
        if ($TestOutDir -eq '') {
            $here = Split-Path -Parent $MyInvocation.MyCommand.Path
            $TestOutDir = Join-Path $here 'DEGROWL_TEST'
        }
        [void][System.IO.Directory]::CreateDirectory($TestOutDir)
        Write-Info ''
        Write-Info ('Rendering comparison files into: ' + $TestOutDir)
        [System.IO.File]::Copy($TestFile, (Join-Path $TestOutDir '0_original.wav'), $true)
        $variants = @('Light', 'Balanced', 'Clean', 'CleanPlus', 'Flat')
        $idx = 1
        foreach ($v in $variants) {
            $st = Get-StrengthSettings $v
            $outF = Join-Path $TestOutDir ('{0}_{1}.wav' -f $idx, $v.ToLowerInvariant())
            try {
                $s = Convert-OneWav $ff $TestFile $outF (New-Options $st)
                Write-Good ('{0}_{1}.wav  ({2})' -f $idx, $v.ToLowerInvariant(), $s)
            } catch { Write-Bad ('{0}: {1}' -f $v, $_.Exception.Message) }
            $idx++
        }
        Write-Info ''
        try { if ($env:OS -eq 'Windows_NT') { Start-Process explorer.exe -ArgumentList ('"' + $TestOutDir + '"') } } catch { }
        if ($Strength -eq 'Ask' -and -not $NoPause) {
            Write-Info ''
            $go = (Read-Host 'Process the whole voicebank now? 1 = Light, 2 = Balanced, 3 = Clean, 4 = Clean+, anything else = stop').Trim()
            if ($go -eq '1') { $Strength = 'Light' } elseif ($go -eq '2') { $Strength = 'Balanced' } elseif ($go -eq '3') { $Strength = 'Clean' } elseif ($go -eq '4') { $Strength = 'CleanPlus' } else { Write-Info 'Done. Nothing else was changed.'; Exit-Tool 0 }
            $Mode = 'Bank'
        } else {
            Exit-Tool 0
        }
    }

    if ($Strength -eq 'Ask') {
        Write-Info ''
        Write-Info 'How strong should the processing be?'
        Write-Info '  1) Light'
        Write-Info '  2) Balanced'
        Write-Info '  3) Clean     (removes the roughness fully)'
        Write-Info '  4) Clean+'
        $go = (Read-Host 'Choose 1, 2, 3 or 4 (default 3)').Trim()
        if ($go -eq '1') { $Strength = 'Light' } elseif ($go -eq '2') { $Strength = 'Balanced' } elseif ($go -eq '4') { $Strength = 'CleanPlus' } else { $Strength = 'Clean' }
    }
    $st = Get-StrengthSettings $Strength

    if ([System.IO.Directory]::Exists($dstRoot) -or [System.IO.File]::Exists($dstRoot)) {
        throw ("The output folder already exists, so nothing was done:`n  $dstRoot`nRename or remove it and run the tool again.")
    }
    $reportPath = $dstRoot + '_report.txt'

    Write-Info ''
    Write-Info 'Ready:'
    Write-Info ('  Source (read only): ' + $src)
    Write-Info ('  New copy:           ' + $dstRoot)
    Write-Info ('  Strength:           ' + $st.Name)
    if (-not $Yes) {
        $ok = (Read-Host 'Start? (Y/N)').Trim().ToUpperInvariant()
        if ($ok -ne 'Y' -and $ok -ne 'YES') { Write-Info 'Cancelled - nothing was changed.'; Exit-Tool 0 }
    }

    [void][System.IO.Directory]::CreateDirectory($dstRoot)
    $srcPrefix = $src + [System.IO.Path]::DirectorySeparatorChar

    foreach ($d in [System.IO.Directory]::GetDirectories($src, '*', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $d.Substring($srcPrefix.Length)
        [void][System.IO.Directory]::CreateDirectory((Join-Path $dstRoot $rel))
    }

    $copied = 0; $skipped = New-Object System.Collections.ArrayList
    foreach ($f in $allFiles) {
        $ext = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
        if ($ext -eq '.wav' -or [System.IO.Path]::GetFileName($f).ToLowerInvariant() -eq 'oto.ini') { continue }
        $rel = $f.Substring($srcPrefix.Length)
        if ($script:SkipExt -contains $ext) { [void]$skipped.Add($rel); continue }
        $target = Join-Path $dstRoot $rel
        [System.IO.File]::Copy($f, $target, $false)
        $copied++
    }

    Write-Info ''
    Write-Info ('Processing {0} WAV files...' -f $wavs.Count)
    $opt = New-Options $st
    $okList = New-Object System.Collections.ArrayList
    $failList = New-Object System.Collections.ArrayList
    $i = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($w in $wavs) {
        $i++
        $rel = $w.Substring($srcPrefix.Length)
        $target = Join-Path $dstRoot $rel
        Write-Progress -Activity $script:ToolName -Status ('{0} / {1}  {2}' -f $i, $wavs.Count, $rel) -PercentComplete ([int](100.0 * $i / $wavs.Count))
        try {
            $s = Convert-OneWav $ff $w $target $opt
            [void]$okList.Add(($rel + '  [' + $s + ']'))
        } catch {
            $msg = $_.Exception.Message
            [void]$failList.Add(($rel + '  -> ' + $msg))
            Write-Bad ($rel + ': ' + $msg)
            try {
                $dir = [System.IO.Path]::GetDirectoryName($target)
                if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
                [System.IO.File]::Copy($w, $target, $true)
            } catch { Write-Bad ('Could not even copy the original: ' + $_.Exception.Message) }
        }
    }
    Write-Progress -Activity $script:ToolName -Completed
    $sw.Stop()

    $charResults = New-Object System.Collections.ArrayList
    foreach ($c in [System.IO.Directory]::GetFiles($dstRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        if ([System.IO.Path]::GetFileName($c).ToLowerInvariant() -eq 'character.txt') {
            $res = Update-CharacterTxt $c
            [void]$charResults.Add(($c.Substring($dstRoot.Length + 1) + ': ' + $res))
        }
    }
    if ($charResults.Count -eq 0) { [void]$charResults.Add('no character.txt found in the bank') }

    $otoResults = New-Object System.Collections.ArrayList
    if ($Oto -eq 'Regenerate') {
        Write-Info 'Generating oto.ini in ANSI (Shift-JIS)...'
        foreach ($r in (Update-OtoFiles $dstRoot $dstRoot)) { [void]$otoResults.Add($r) }
    } else { [void]$otoResults.Add('kept unchanged') }

    $stale = 0
    foreach ($c in [System.IO.Directory]::GetFiles($dstRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        if ($script:SkipExt -contains [System.IO.Path]::GetExtension($c).ToLowerInvariant()) { Remove-Item -LiteralPath $c -Force; $stale++ }
    }

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add($script:ToolName + ' - report')
    [void]$lines.Add('Source:   ' + $src)
    [void]$lines.Add('Output:   ' + $dstRoot)
    [void]$lines.Add('Strength: ' + $st.Name)
    [void]$lines.Add('ffmpeg:   ' + $ver)
    [void]$lines.Add('')
    [void]$lines.Add(('WAV processed OK: {0}   failed: {1}' -f $okList.Count, $failList.Count))
    foreach ($c in $charResults) { [void]$lines.Add('character.txt -> ' + $c) }
    foreach ($c in $otoResults) { [void]$lines.Add('oto.ini -> ' + $c) }
    [System.IO.File]::WriteAllLines($reportPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($true)))

    Write-Info ''
    Write-Host '=== Finished ===' -ForegroundColor Cyan
    Write-Info ('Processed OK : {0}' -f $okList.Count)
    Write-Info ('New voicebank: ' + $dstRoot)
    Write-Info ('Report       : ' + $reportPath)
    Exit-Tool 0
}
catch {
    Write-Host ''
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Nothing in your original voicebank was changed.'
    Exit-Tool 1
}