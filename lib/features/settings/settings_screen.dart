import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config/env.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '…';
  bool _dark = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _version = '${info.version} (${info.buildNumber})');
      }
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rawUrl = Env.supabaseUrl;
    final domain = rawUrl == null ? '' : (Uri.tryParse(rawUrl)?.host ?? '');
    return Scaffold(
      appBar: shellAppBar(context, title: 'Settings'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: 'Appearance',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Dark mode',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Follows your device theme',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary(context)),
                ),
                value: _dark,
                activeTrackColor: AppColors.green,
                onChanged: (v) => setState(() {
                  _dark = v;
                  _snack('Dark mode is planned for a future release.');
                }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Data & storage',
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Clear cached data',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Instagram-like local cache is minimal',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary(context)),
                ),
                trailing: const Icon(
                  Icons.cleaning_services_outlined,
                  size: 18,
                ),
                onTap: () => _snack('Cache cleared.'),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'App version',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _version,
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary(context)),
                ),
                trailing: const Icon(Icons.info_outline, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Connection',
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.cloud_done_outlined,
                  size: 20,
                  color: AppColors.green,
                ),
                title: const Text(
                  'Supabase backend',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  domain,
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary(context)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
