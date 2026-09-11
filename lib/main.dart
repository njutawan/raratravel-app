import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'app.dart';
import 'services/firebase_bootstrap.dart';
import 'services/messaging_service.dart';

/// Entry point aplikasi Rara Travel & Tour.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Format tanggal Indonesia (Senin, Selasa, dst.)
  await initializeDateFormatting('id_ID', null);
  await FirebaseBootstrap.init(); // gagal = mode offline, aplikasi tetap jalan
  if (FirebaseBootstrap.ready) await MessagingService.init(); // worker push
  runApp(const RaraTravelApp());
}
