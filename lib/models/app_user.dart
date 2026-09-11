/// Profil pengguna — tersimpan di Firestore (`users/{uid}`).
class AppUser {
  final String uid;
  final String phone; // format +62...
  final String name;
  final String email;
  final List<String> fcmTokens;
  final String createdAt; // ISO datetime

  AppUser({
    required this.uid,
    required this.phone,
    this.name = '',
    this.email = '',
    this.fcmTokens = const [],
    String? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toIso8601String();

  /// +62812... → 0812... (format lokal untuk form & tampilan).
  String get phoneLocal {
    if (phone.startsWith('+62')) return '0${phone.substring(3)}';
    return phone;
  }

  Map<String, dynamic> toMap() => {
    'phone': phone,
    'name': name,
    'email': email,
    'fcmTokens': fcmTokens,
    'createdAt': createdAt,
  };

  factory AppUser.fromMap(String uid, Map<String, dynamic> m) => AppUser(
    uid: uid,
    phone: (m['phone'] ?? '') as String,
    name: (m['name'] ?? '') as String,
    email: (m['email'] ?? '') as String,
    fcmTokens: ((m['fcmTokens'] as List?) ?? [])
        .map((e) => e.toString())
        .toList(),
    createdAt: m['createdAt'] as String?,
  );
}
