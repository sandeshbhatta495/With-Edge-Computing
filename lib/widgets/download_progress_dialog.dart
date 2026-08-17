import 'package:flutter/material.dart';

import '../models/download_progress.dart';

class DownloadProgressDialog extends StatelessWidget {
  final ValueNotifier<DownloadProgress?> progressNotifier;
  final VoidCallback onCancel;

  const DownloadProgressDialog({
    super.key,
    required this.progressNotifier,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Downloading Offline Map'),
      content: ValueListenableBuilder<DownloadProgress?>(
        valueListenable: progressNotifier,
        builder: (context, progress, child) {
          if (progress == null) {
            return const SizedBox(
              height: 80,
              child: Center(
                child: CircularProgressIndicator(),
              ),
            );
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: progress.percentage,
              ),

              const SizedBox(height: 20),

              Text(
                progress.percentageText,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),

              const SizedBox(height: 10),

              Text(
                '${progress.downloadedTiles} / ${progress.totalTiles} tiles',
              ),

              const SizedBox(height: 6),

              Text(
                'Zoom Level ${progress.currentZoom}',
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}