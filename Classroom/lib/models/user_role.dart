enum UserRole {
  admin,
  teacher;

  String get displayName => this == UserRole.admin ? 'Administrator' : 'Teacher';
  String get code => this == UserRole.admin ? 'admin' : 'teacher';
  String get badgeLabel => this == UserRole.admin ? 'ADMIN' : 'TEACHER';
  String get description => this == UserRole.admin
      ? 'Full system access · Hardware provisioning & management'
      : 'Classroom access · View and operate connected appliances';

  static UserRole fromCode(String? code) {
    if (code == null) return UserRole.admin;
    final clean = code.trim().toLowerCase();
    if (clean == 'teacher' || clean == 'educator') return UserRole.teacher;
    return UserRole.admin;
  }
}

const List<String> kCampusDepartments = [
  'Computer Science & Engineering (CSE)',
  'Electrical & Electronic Engineering (EEE)',
  'Mechanical Engineering (ME)',
  'Civil Engineering (CE)',
  'Electronics & Telecommunication Engineering (ETE)',
  'Industrial & Production Engineering (IPE)',
  'Information & Communication Engineering (ICE)',
  'Mechatronics Engineering (MTE)',
  'Architecture (ARCH)',
  'Physics & Natural Sciences',
  'Mathematics & Humanities',
  'General Administration',
];

String getDepartmentShortName(String dept) {
  final clean = dept.trim();
  if (clean.isEmpty) return 'GENERAL';
  final match = RegExp(r'\(([^)]+)\)').firstMatch(clean);
  if (match != null && match.group(1) != null) {
    return match.group(1)!.trim().toUpperCase();
  }
  if (clean.length <= 6) return clean.toUpperCase();
  if (clean.toLowerCase().contains('general') || clean.toLowerCase().contains('admin')) {
    return 'ADMIN';
  }
  if (clean.toLowerCase().contains('physics') || clean.toLowerCase().contains('science')) {
    return 'SCIENCES';
  }
  if (clean.toLowerCase().contains('math')) {
    return 'MATH';
  }
  final words = clean.split(RegExp(r'\s+'));
  if (words.length > 1) {
    return words.map((w) => w[0]).join().toUpperCase();
  }
  return clean.substring(0, clean.length > 8 ? 8 : clean.length).toUpperCase();
}


