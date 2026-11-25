import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'caption_dictionary.dart';
import 'caption_tts_service.dart';

/// 弹出发音引擎与音色设置弹窗（支持 Edge-TTS、小米 MiMo-V2.5-TTS、系统原生）
Future<void> showTtsVoiceSettingsDialog(
  BuildContext context, {
  String? testWord,
  String? language,
}) async {
  final service = CaptionTtsService.shared;
  var currentConfig = service.config;

  final apiKeyController = TextEditingController(text: currentConfig.mimoApiKey);
  final baseUrlController = TextEditingController(text: currentConfig.mimoBaseUrl);

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;
          final isMiMo = currentConfig.engine == 'mimo';
          final isEdge = currentConfig.engine == 'edge';

          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.record_voice_over_rounded, color: colorScheme.primary, size: 22),
                const SizedBox(width: 8),
                const Text('查词与注音发音设置', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ],
            ),
            contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '发音引擎选择',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 1. Edge-TTS
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: 'edge',
                      groupValue: currentConfig.engine,
                      title: const Text('Microsoft Edge-TTS (推荐 · 内置免费)'),
                      subtitle: const Text('免 API Key，内置纯正香港粤语发音人，秒速播放', style: TextStyle(fontSize: 11)),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            currentConfig = CaptionTtsConfig(
                              engine: val,
                              edgeCantoneseVoice: currentConfig.edgeCantoneseVoice,
                              edgeMandarinVoice: currentConfig.edgeMandarinVoice,
                              mimoVoice: currentConfig.mimoVoice,
                              mimoApiKey: currentConfig.mimoApiKey,
                              mimoBaseUrl: currentConfig.mimoBaseUrl,
                            );
                          });
                        }
                      },
                    ),
                    // 2. MiMo-V2.5-TTS
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: 'mimo',
                      groupValue: currentConfig.engine,
                      title: Row(
                        children: [
                          const Text('小米 MiMo-V2.5-TTS'),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '限时免费',
                              style: TextStyle(fontSize: 10, color: Colors.deepOrange, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      subtitle: const Text('大模型拟真情感与方言语音，支持 [粤语] 标签，需填 Key', style: TextStyle(fontSize: 11)),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            currentConfig = CaptionTtsConfig(
                              engine: val,
                              edgeCantoneseVoice: currentConfig.edgeCantoneseVoice,
                              edgeMandarinVoice: currentConfig.edgeMandarinVoice,
                              mimoVoice: currentConfig.mimoVoice,
                              mimoApiKey: currentConfig.mimoApiKey,
                              mimoBaseUrl: currentConfig.mimoBaseUrl,
                            );
                          });
                        }
                      },
                    ),
                    // 3. 系统原生
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: 'system',
                      groupValue: currentConfig.engine,
                      title: const Text('系统原生离线 TTS'),
                      subtitle: const Text('使用设备内置语音引擎，断网时兜底', style: TextStyle(fontSize: 11)),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            currentConfig = CaptionTtsConfig(
                              engine: val,
                              edgeCantoneseVoice: currentConfig.edgeCantoneseVoice,
                              edgeMandarinVoice: currentConfig.edgeMandarinVoice,
                              mimoVoice: currentConfig.mimoVoice,
                              mimoApiKey: currentConfig.mimoApiKey,
                              mimoBaseUrl: currentConfig.mimoBaseUrl,
                            );
                          });
                        }
                      },
                    ),
                    const Divider(height: 16),

                    // Edge-TTS 音色选择
                    if (isEdge || currentConfig.engine == 'system') ...[
                      Text(
                        '粤语发音人 (Edge-TTS)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorScheme.outline),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceVariant.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButton<String>(
                          value: currentConfig.edgeCantoneseVoice,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: CaptionTtsService.edgeCantoneseVoices.entries
                              .map((e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value, style: const TextStyle(fontSize: 13)),
                                  ))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                currentConfig = CaptionTtsConfig(
                                  engine: currentConfig.engine,
                                  edgeCantoneseVoice: val,
                                  edgeMandarinVoice: currentConfig.edgeMandarinVoice,
                                  mimoVoice: currentConfig.mimoVoice,
                                  mimoApiKey: currentConfig.mimoApiKey,
                                  mimoBaseUrl: currentConfig.mimoBaseUrl,
                                );
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '普通话发音人 (Edge-TTS)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorScheme.outline),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceVariant.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButton<String>(
                          value: currentConfig.edgeMandarinVoice,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: CaptionTtsService.edgeMandarinVoices.entries
                              .map((e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value, style: const TextStyle(fontSize: 13)),
                                  ))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                currentConfig = CaptionTtsConfig(
                                  engine: currentConfig.engine,
                                  edgeCantoneseVoice: currentConfig.edgeCantoneseVoice,
                                  edgeMandarinVoice: val,
                                  mimoVoice: currentConfig.mimoVoice,
                                  mimoApiKey: currentConfig.mimoApiKey,
                                  mimoBaseUrl: currentConfig.mimoBaseUrl,
                                );
                              });
                            }
                          },
                        ),
                      ),
                    ],

                    // MiMo 设置
                    if (isMiMo) ...[
                      Text(
                        '小米 MiMo 音色选择',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorScheme.outline),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceVariant.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButton<String>(
                          value: currentConfig.mimoVoice,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: CaptionTtsService.mimoVoices.entries
                              .map((e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value, style: const TextStyle(fontSize: 13)),
                                  ))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                currentConfig = CaptionTtsConfig(
                                  engine: currentConfig.engine,
                                  edgeCantoneseVoice: currentConfig.edgeCantoneseVoice,
                                  edgeMandarinVoice: currentConfig.edgeMandarinVoice,
                                  mimoVoice: val,
                                  mimoApiKey: currentConfig.mimoApiKey,
                                  mimoBaseUrl: currentConfig.mimoBaseUrl,
                                );
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'MiMo API Key (前往 mimo.mi.com 申请)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorScheme.outline),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: apiKeyController,
                        obscureText: true,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          hintText: '输入小米开放平台 API Key (选填)',
                          hintStyle: const TextStyle(fontSize: 12),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onChanged: (val) {
                          setState(() {
                            currentConfig = CaptionTtsConfig(
                              engine: currentConfig.engine,
                              edgeCantoneseVoice: currentConfig.edgeCantoneseVoice,
                              edgeMandarinVoice: currentConfig.edgeMandarinVoice,
                              mimoVoice: currentConfig.mimoVoice,
                              mimoApiKey: val.trim(),
                              mimoBaseUrl: currentConfig.mimoBaseUrl,
                            );
                          });
                        },
                      ),
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceVariant.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline_rounded, size: 14, color: colorScheme.primary),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                apiKeyController.text.trim().isEmpty
                                    ? '💡 提示：未填写 API Key 时，系统将自动映射为 Edge-TTS 对应男女声发音人（如 白桦/苏打 -> 云龙男声，冰糖 -> 晓曼女声），免密即可直接播放。'
                                    : '已配置 API Key，将直接调用小米 MiMo-V2.5-TTS 大模型语音服务。',
                                style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'API Base URL (可选)',
                        style: TextStyle(fontSize: 12, color: colorScheme.outline),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: baseUrlController,
                        style: const TextStyle(fontSize: 12),
                        decoration: InputDecoration(
                          hintText: '默认: https://api.xiaomimimo.com/v1',
                          hintStyle: const TextStyle(fontSize: 11),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onChanged: (val) {
                          currentConfig = CaptionTtsConfig(
                            engine: currentConfig.engine,
                            edgeCantoneseVoice: currentConfig.edgeCantoneseVoice,
                            edgeMandarinVoice: currentConfig.edgeMandarinVoice,
                            mimoVoice: currentConfig.mimoVoice,
                            mimoApiKey: currentConfig.mimoApiKey,
                            mimoBaseUrl: val.trim().isNotEmpty ? val.trim() : CaptionTtsConfig.defaultMiMoBaseUrl,
                          );
                        },
                      ),
                    ],

                    const SizedBox(height: 16),
                    // 试听按钮
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final sampleText = (testWord != null && testWord.isNotEmpty) ? testWord : '知不';
                            final isMandarin = language == 'zh-CN' || language == 'zh';
                            SmartDialog.showLoading(msg: '正在试听发音…');
                            try {
                              // 更新临时配置以便试听
                              await service.updateConfig(
                                engine: currentConfig.engine,
                                edgeCantoneseVoice: currentConfig.edgeCantoneseVoice,
                                edgeMandarinVoice: currentConfig.edgeMandarinVoice,
                                mimoVoice: currentConfig.mimoVoice,
                                mimoApiKey: apiKeyController.text.trim(),
                                mimoBaseUrl: baseUrlController.text.trim(),
                              );
                              await WordAudioPlayer.shared.play(
                                '',
                                speakText: sampleText,
                                speakLang: isMandarin ? 'zh-CN' : 'zh-HK',
                              );
                              SmartDialog.dismiss();
                            } catch (e) {
                              SmartDialog.dismiss();
                              SmartDialog.showToast('试听失败: $e');
                            }
                          },
                          icon: const Icon(Icons.volume_up_rounded, size: 16),
                          label: Text('试听「${(testWord != null && testWord.isNotEmpty) ? (testWord.length > 6 ? "${testWord.substring(0, 6)}…" : testWord) : '发音'}」${(language == 'zh-CN' || language == 'zh') ? '普通话' : '粤语'}发音'),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  await service.updateConfig(
                    engine: currentConfig.engine,
                    edgeCantoneseVoice: currentConfig.edgeCantoneseVoice,
                    edgeMandarinVoice: currentConfig.edgeMandarinVoice,
                    mimoVoice: currentConfig.mimoVoice,
                    mimoApiKey: apiKeyController.text.trim(),
                    mimoBaseUrl: baseUrlController.text.trim(),
                  );
                  SmartDialog.showToast('已保存发音设置');
                  Navigator.of(context).pop();
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    },
  );
}

