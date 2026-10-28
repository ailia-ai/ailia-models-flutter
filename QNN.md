# QNN Setup

QNN (HTP) is available for ailia LLM (LLM, VLM, ALM and Tool Use) and
ailia Speech (Whisper Medium / Large V3 Turbo). The ailia SDK QNN backend
for the other models is not included in this release.

## Windows ARM64 LLM

Gemma 4 E2B uses the NPU by default when the Windows ARM64 process can
detect `sc8380xp` or `qcs6490` through `AiliaLLMModel.getQNNModelName()` and
the LLM `HTP` backend is available. Selecting `HTP` downloads the matching
`gemma4-e2b-<soc>.qnn` from `gemma/qnn/v1.5.0` in the ailia model storage,
caches it in the normal model directory, and opens it with `n_ctx=0`
(the package's compiled 8192-token context). Selecting CPU/GPU downloads
and opens the usual GGUF. Gemma 2 and Gemma 3 do not offer QNN.

Gemma 4 E2B Tool Use shares the text-chat model cache and follows the same
CPU/GPU or HTP selection. On HTP it uses the detected SoC's `.qnn` package
with `n_ctx=0`; tool definitions and structured JSON history use the same
SDK APIs as CPU/GPU. No multimodal projector is required.

Gemma 4 E2B VLM and ALM additionally download the matching
`gemma4-e2b-<soc>-mmproj.qnn` projector when using HTP.

Gemma 4 E4B text chat uses `gemma-4-E4B-it-Q4_K_M.gguf` on CPU/GPU or
`gemma4-e4b-sc8380xp.qnn` on HTP. E4B's HTP backend is hidden on QCS6490,
which supports E2B only.

Use a QNN-enabled ailia LLM 1.5.0 Windows ARM64 runtime, QAIRT
**2.47.0.260601**, and the Qualcomm NPU driver. The pinned Flutter binding
(`v1.5.0`) provides the SoC API and bundles the LLM/ggml DLLs including
`ailia_llm_qnn.dll`. This is separate from the ailia SDK's QNN plugin.
Prepare a folder with the QAIRT `lib/aarch64-windows-msvc` QNN DLLs and
the matching `lib/hexagon-v73/unsigned` (sc8380xp) or
`lib/hexagon-v68/unsigned` (qcs6490) `.so` and `.cat` files. Set the folder
before building, or place these files beside the built executable:

```powershell
$env:AILIA_LLM_QNN_RUNTIME_DIR = 'C:\QAIRT\windows-arm64-v73'
flutter build windows
```

Only use the package and Hexagon runtime for the actual SoC. QCS6490 is
experimental and requires device verification. See the
[official QNN guide](https://docs.ailia.ai/llm/qnn.html) for runtime setup
and download details.

Build with an ARM64 Flutter SDK on Windows ARM64; an x64 process cannot
load the ARM64 QNN plugin.
