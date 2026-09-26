/*
 * audio2wav — 用 Windows Media Foundation 系统解码器把 MP3 / M4A·AAC /
 * WAV / FLAC 解码为 16-bit PCM WAV（不随包带任何编解码库）：
 *   - MP3 / AAC(M4A) / WAV：Windows 自带；
 *   - FLAC：Windows 10+ 自带。
 *
 * 缺省保留源采样率与声道（适合音色库参考音频等保真场景，避免二次重采样）；
 * 用 --rate / --channels 指定目标（ASR 需要 --rate 16000 --channels 1）。
 *
 * 用法: audio2wav <input> <output.wav> [--rate <hz>] [--channels <n>]
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdio.h>
#include <stdlib.h>

static void put32(FILE *f, DWORD v) { fwrite(&v, 4, 1, f); }
static void put16(FILE *f, WORD v) { fwrite(&v, 2, 1, f); }

static void write_wav_header(FILE *f, DWORD sample_rate, WORD channels,
                             DWORD data_bytes) {
  WORD bits = 16;
  WORD block_align = (WORD)(channels * (bits / 8));
  DWORD byte_rate = sample_rate * block_align;
  DWORD riff_size = 36 + data_bytes;
  WORD fmt = 1; /* PCM */

  fwrite("RIFF", 1, 4, f);
  put32(f, riff_size);
  fwrite("WAVE", 1, 4, f);
  fwrite("fmt ", 1, 4, f);
  put32(f, 16);
  put16(f, fmt);
  put16(f, channels);
  put32(f, sample_rate);
  put32(f, byte_rate);
  put16(f, block_align);
  put16(f, bits);
  fwrite("data", 1, 4, f);
  put32(f, data_bytes);
}

static HRESULT set_output_type(IMFSourceReader *reader, UINT32 rate,
                               UINT32 channels) {
  IMFMediaType *type = NULL;
  HRESULT hr = MFCreateMediaType(&type);
  if (FAILED(hr)) return hr;
  IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
  IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, &MFAudioFormat_PCM);
  IMFMediaType_SetUINT32(type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  if (channels) {
    IMFMediaType_SetUINT32(type, &MF_MT_AUDIO_NUM_CHANNELS, channels);
  }
  if (rate) {
    IMFMediaType_SetUINT32(type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
  }
  hr = IMFSourceReader_SetCurrentMediaType(
      reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, type);
  IMFMediaType_Release(type);
  return hr;
}

int wmain(int argc, wchar_t **argv) {
  if (argc < 3) {
    fwprintf(stderr,
             L"usage: audio2wav <input> <output.wav> [--rate <hz>] "
             L"[--channels <n>]\n");
    return 2;
  }
  UINT32 req_rate = 0, req_channels = 0; /* 0 = 保留源采样率/声道 */
  for (int i = 3; i < argc; i++) {
    if (!wcscmp(argv[i], L"--rate") && i + 1 < argc) {
      req_rate = (UINT32)_wtoi(argv[++i]);
    } else if (!wcscmp(argv[i], L"--channels") && i + 1 < argc) {
      req_channels = (UINT32)_wtoi(argv[++i]);
    } else {
      fwprintf(stderr, L"unknown argument: %ls\n", argv[i]);
      return 2;
    }
  }
  HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (FAILED(hr)) {
    fwprintf(stderr, L"CoInitializeEx failed (0x%08X)\n", (unsigned)hr);
    return 1;
  }
  hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(hr)) {
    fwprintf(stderr, L"MFStartup failed (0x%08X)\n", (unsigned)hr);
    CoUninitialize();
    return 1;
  }

  IMFSourceReader *reader = NULL;
  hr = MFCreateSourceReaderFromURL(argv[1], NULL, &reader);
  if (FAILED(hr)) {
    fwprintf(stderr, L"open failed (0x%08X)\n", (unsigned)hr);
    MFShutdown();
    CoUninitialize();
    return 1;
  }

  /* 读取源原生采样率/声道：未显式指定时按源保留（音色库等保真场景）。 */
  UINT32 src_rate = 0, src_channels = 0;
  IMFMediaType *native = NULL;
  if (SUCCEEDED(IMFSourceReader_GetNativeMediaType(
          reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &native)) &&
      native != NULL) {
    IMFMediaType_GetUINT32(native, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &src_rate);
    IMFMediaType_GetUINT32(native, &MF_MT_AUDIO_NUM_CHANNELS, &src_channels);
    IMFMediaType_Release(native);
  }

  /* 请求 PCM 目标；保留源或指定目标，失败再回退为默认 PCM。 */
  const UINT32 want_rate = req_rate ? req_rate : src_rate;
  const UINT32 want_channels = req_channels ? req_channels : src_channels;
  if (FAILED(set_output_type(reader, want_rate, want_channels)) &&
      FAILED(set_output_type(reader, 0, 0))) {
    fwprintf(stderr, L"no PCM output type available\n");
    IMFSourceReader_Release(reader);
    MFShutdown();
    CoUninitialize();
    return 1;
  }

  UINT32 rate = 0, channels = 0;
  IMFMediaType *cur = NULL;
  if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(
          reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &cur)) &&
      cur != NULL) {
    IMFMediaType_GetUINT32(cur, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
    IMFMediaType_GetUINT32(cur, &MF_MT_AUDIO_NUM_CHANNELS, &channels);
    IMFMediaType_Release(cur);
  }
  if (rate == 0) rate = 16000;
  if (channels == 0) channels = 1;

  FILE *out = _wfopen(argv[2], L"wb");
  if (out == NULL) {
    fwprintf(stderr, L"cannot write output\n");
    IMFSourceReader_Release(reader);
    MFShutdown();
    CoUninitialize();
    return 1;
  }

  write_wav_header(out, rate, (WORD)channels, 0);
  DWORD total = 0;
  int failed = 0;

  for (;;) {
    DWORD flags = 0;
    IMFSample *sample = NULL;
    hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                                    0, NULL, &flags, NULL, &sample);
    if (FAILED(hr)) {
      failed = 1;
      break;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    if (sample != NULL) {
      IMFMediaBuffer *buf = NULL;
      hr = IMFSample_ConvertToContiguousBuffer(sample, &buf);
      if (SUCCEEDED(hr) && buf != NULL) {
        BYTE *p = NULL;
        DWORD cb = 0;
        hr = IMFMediaBuffer_Lock(buf, &p, NULL, &cb);
        if (SUCCEEDED(hr) && cb > 0) {
          fwrite(p, 1, cb, out);
          total += cb;
          IMFMediaBuffer_Unlock(buf);
        }
        IMFMediaBuffer_Release(buf);
      }
      IMFSample_Release(sample);
    }
  }

  if (total > 0) {
    fseek(out, 0, SEEK_SET);
    write_wav_header(out, rate, (WORD)channels, total);
  }
  fclose(out);

  IMFSourceReader_Release(reader);
  MFShutdown();
  CoUninitialize();

  if (failed || total == 0) {
    fwprintf(stderr, L"decode failed\n");
    _wremove(argv[2]);
    return 1;
  }
  return 0;
}
