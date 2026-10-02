/// FP16 policy from ailia-models-kotlin PR #33 / QAIRT 2.47
/// PyBackendInfo("HTP", soc).get_soc_info_subset().supportsFp16.
/// Update this table when updating QAIRT; Hexagon version alone is insufficient.
const _fp16UnsupportedSocs = {
  // HTP architecture undefined.
  'cq4390m', 'cq4390s', 'qcm2290', 'qcm4490', 'qcs2290', 'qcs4490',
  'sa525m', 'sg4250', 'sg4250p', 'sm4450', 'sm4635', 'sm4850',
  'sm4850p', 'sm6435', 'sm6450q', 'sm6475q', 'sm6850', 'sm6850q',
  // Hexagon v65.
  'sm7150',
  // Hexagon v66.
  'cq2390m', 'cq2390s', 'qcm6125', 'qcs403', 'qcs405', 'qcs410',
  'qcs610', 'qcs6125', 'qcs615', 'qcs7230', 'qrb4210', 'qrb5165',
  'sa8195', 'sm4250', 'sm4350', 'sm4375', 'sm6115', 'sm6115p',
  'sm6125', 'sm6150', 'sm6250', 'sm6350', 'sm6370', 'sm6375',
  'sm7225', 'sm7250', 'sm8150', 'sm8250',
  // Hexagon v68.
  'qcm5430', 'qcm6490', 'qcs5430', 'qcs6490', 'sc7280x', 'sc8280x',
  'sm7315', 'sm7325', 'sm7350', 'sm8325', 'sm8350', 'sm8350p',
  // Hexagon v69.
  'sm7475',
  // Hexagon v73.
  'cq7790m', 'cq7790s', 'qcm6690', 'qcs6690', 'qmb715', 'qna715',
  'sg6150', 'sg6150p', 'sm6450', 'sm6475', 'sm6475p', 'sm6650',
  'sm6650p', 'sm7435', 'sm7435p', 'sm7525', 'sm7550', 'sm7550p',
  'sm7635', 'sm7635p', 'sm7675', 'sm7675p', 'sm7750', 'sm7750p',
  'sm7775', 'sm8635', 'sm8635p', 'sm8735', 'sm8735p', 'ssg2115p',
  'ssg2125p', 'sxr1230p',
};

/// Unknown or unavailable SoCs retain the existing SDK behavior.
bool isQnnFp16SupportedSoc(String? soc) =>
    !_fp16UnsupportedSocs.contains(soc?.trim().toLowerCase());

/// SDK demos use HTP only, and require FP16 on that SoC.
bool isSdkQnnEnvironmentSelectable(String name, String? soc) {
  final upper = name.toUpperCase();
  return !upper.contains('QNN') ||
      (isQnnFp16SupportedSoc(soc) &&
          !upper.contains('CPU') &&
          !upper.contains('GPU'));
}

/// Quantized ailia LLM context binaries do not require SDK FP16 support.
bool showQnnMark({
  required bool qnnSupported,
  required bool usesLlmBackend,
  required String? soc,
}) =>
    qnnSupported && (usesLlmBackend || isQnnFp16SupportedSoc(soc));
