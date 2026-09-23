import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../diff/domain/diff_result.dart';

/// Top stats bar: +N -M ~K. PRD §2 Module 5.
class DiffStatsBar extends StatelessWidget {
  const DiffStatsBar({required this.result, super.key});

  final DiffResult result;

  @override
  Widget build(BuildContext context) {
    final s = result.stats;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _Badge(
            count: '+${s.added}',
            color: AppColors.addedOf(context),
            icon: Icons.add_circle,
          ),
          const SizedBox(width: 8),
          _Badge(
            count: '-${s.deleted}',
            color: AppColors.deletedOf(context),
            icon: Icons.remove_circle,
          ),
          const SizedBox(width: 8),
          _Badge(
            count: '~${s.modified}',
            color: AppColors.modifiedOf(context),
            icon: Icons.edit,
          ),
          const Spacer(),
          Text(
            s.engineType.name,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.count,
    required this.color,
    required this.icon,
  });

  final String count;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(count,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 13)),
        ],
      ),
    );
  }
}
