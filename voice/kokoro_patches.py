"""Runtime patches for mlx-audio 0.4.4 Kokoro length-mismatch bugs.

For certain input lengths the harmonic-source branch and the main
upsampling branch of the iSTFT vocoder disagree by a few frames
("[broadcast_shapes] … cannot be broadcast"). Both patched methods are
verbatim copies of the originals with explicit time-axis alignment
(pad-with-edge / trim — sub-15 ms, inaudible). Remove once fixed
upstream (github.com/Blaizzy/mlx-audio).
"""
import mlx.core as mx
from mlx_audio.tts.models.kokoro import istftnet
from mlx_audio.tts.models.kokoro.istftnet import leaky_relu


def _align_time(tensor, target_len, axis):
    current = tensor.shape[axis]
    if current == target_len:
        return tensor
    if current > target_len:
        slicer = [slice(None)] * tensor.ndim
        slicer[axis] = slice(0, target_len)
        return tensor[tuple(slicer)]
    edge_slicer = [slice(None)] * tensor.ndim
    edge_slicer[axis] = slice(current - 1, current)
    pad = mx.repeat(tensor[tuple(edge_slicer)], target_len - current, axis=axis)
    return mx.concatenate([tensor, pad], axis=axis)


def _sinegen_call(self, f0):
    fn = f0 * mx.arange(1, self.harmonic_num + 2)[None, None, :]
    sine_waves = self._f02sine(fn) * self.sine_amp
    uv = self._f02uv(f0)
    uv = _align_time(uv, sine_waves.shape[1], axis=1)          # patch
    noise_amp = uv * self.noise_std + (1 - uv) * self.sine_amp / 3
    noise = noise_amp * mx.random.normal(sine_waves.shape)
    sine_waves = sine_waves * uv + noise
    return sine_waves, uv, noise


def _generator_call(self, x, s, f0):
    f0 = self.f0_upsamp(f0[:, None].transpose(0, 2, 1))
    har_source, noi_source, uv = self.m_source(f0)
    har_source = mx.squeeze(har_source.transpose(0, 2, 1), axis=1)
    har_spec, har_phase = self.stft.transform(har_source)
    har = mx.concatenate([har_spec, har_phase], axis=1)
    har = har.swapaxes(2, 1)
    for i in range(self.num_upsamples):
        x = leaky_relu(x, negative_slope=0.1)
        x_source = self.noise_convs[i](har)
        x_source = x_source.swapaxes(2, 1)
        x_source = self.noise_res[i](x_source, s)

        x = x.swapaxes(2, 1)
        x = self.ups[i](x, mx.conv_transpose1d)
        x = x.swapaxes(2, 1)

        if i == self.num_upsamples - 1:
            x = self.reflection_pad(x)
        x_source = _align_time(x_source, x.shape[2], axis=2)   # patch
        x = x + x_source

        xs = None
        for j in range(self.num_kernels):
            if xs is None:
                xs = self.resblocks[i * self.num_kernels + j](x, s)
            else:
                xs += self.resblocks[i * self.num_kernels + j](x, s)
        x = xs / self.num_kernels

    x = leaky_relu(x, negative_slope=0.01)

    x = x.swapaxes(2, 1)
    x = self.conv_post(x, mx.conv1d)
    x = x.swapaxes(2, 1)

    spec = mx.exp(x[:, : self.post_n_fft // 2 + 1, :])
    phase = mx.sin(x[:, self.post_n_fft // 2 + 1 :, :])
    return self.stft.inverse(spec, phase)


def apply():
    istftnet.SineGen.__call__ = _sinegen_call
    istftnet.Generator.__call__ = _generator_call
