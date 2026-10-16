Map<String, dynamic> mediaPromptMessage(
    String text, String path, String mediaType) {
  if (mediaType != 'image' && mediaType != 'audio') {
    throw ArgumentError('Unsupported media type: $mediaType');
  }
  return {
    'role': 'user',
    // Gemma 4 works best with images before the text and audio after it.
    'content':
        mediaType == 'image' ? '<__media__>\n$text' : '$text <__media__>',
    'media_data': [
      {
        'media_type': mediaType,
        'file_path': path,
        if (mediaType == 'image') 'width': 0,
        if (mediaType == 'image') 'height': 0,
      },
    ],
  };
}

List<Map<String, dynamic>> mediaPromptMessages({
  required String systemPrompt,
  required String inputText,
  required String mediaPath,
  required String mediaType,
}) {
  return [
    if (systemPrompt.isNotEmpty) {'role': 'system', 'content': systemPrompt},
    mediaPromptMessage(inputText, mediaPath, mediaType),
  ];
}
