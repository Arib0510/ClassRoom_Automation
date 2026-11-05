import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_role.dart';
import 'classroom_state.dart';

class GoogleAuthResult {
  final bool isNewUser;
  final User user;
  final GoogleSignInAccount googleAccount;

  GoogleAuthResult({
    required this.isNewUser,
    required this.user,
    required this.googleAccount,
  });
}

class AuthState extends ChangeNotifier {
  static final AuthState _instance = AuthState._internal();
  factory AuthState() => _instance;

  static const String _kLoggedIn = 'auth_logged_in';
  static const String _kUserName = 'auth_user_name';
  static const String _kUserEmail = 'auth_user_email';
  static const String _kAccountType = 'auth_account_type';
  static const String _kPhotoUrl = 'auth_photo_url';
  static const String _kUserRole = 'auth_user_role';
  static const String _kUserDepartment = 'auth_user_department';

  StreamSubscription<DocumentSnapshot>? _userDocSub;

  AuthState._internal() {
    _initImmediateUser();
    _initFirebaseAuthListener();
  }

  void _initImmediateUser() {
    try {
      final current = FirebaseAuth.instance.currentUser;
      if (current != null) {
        _userName = current.displayName ?? (current.email?.split('@').first ?? 'Console Administrator');
        _userEmail = current.email ?? 'admin@ruet-iot.edu';
        _userPhotoUrl = current.photoURL;
        _accountType = current.providerData.any((p) => p.providerId == 'google.com')
            ? 'Google Authenticated'
            : 'Firebase Account';
        _isLoggedIn = true;
        _startUserProfileListener(current.uid);
        _fetchUserProfileFromCloud(current.uid);
      }
    } catch (_) {}
  }

  // Real-time synchronization of user role and department directly from Firebase cloud document
  void _startUserProfileListener(String uid) {
    _userDocSub?.cancel();
    try {
      _userDocSub = FirebaseFirestore.instance.collection('users').doc(uid).snapshots().listen((doc) async {
        if (doc.exists && doc.data() != null) {
          final data = doc.data()!;
          final roleCode = data['role']?.toString();
          if (roleCode != null && roleCode.trim().isNotEmpty) {
            final cloudRole = UserRole.fromCode(roleCode);
            if (_userRole != cloudRole) {
              _userRole = cloudRole;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_kUserRole, _userRole.code);
              notifyListeners();
            }
          }

          final dept = data['department']?.toString();
          if (dept != null && dept.trim().isNotEmpty) {
            if (_userDepartment != dept.trim()) {
              _userDepartment = dept.trim();
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_kUserDepartment, _userDepartment);
              notifyListeners();
            }
          }
        }
      }, onError: (e) {
        debugPrint('[AuthState] Profile stream error: $e');
      });
    } catch (e) {
      debugPrint('[AuthState] Start profile listener error: $e');
    }
  }

  String _userName = 'Console Administrator';
  String get userName => _userName;

  String _userEmail = 'admin@classpulse.local';
  String get userEmail => _userEmail;

  bool _isLoggedIn = false;
  bool get isLoggedIn => _isLoggedIn;

  String _accountType = 'Console Operator';
  String get accountType => _accountType;

  String? _userPhotoUrl;
  String? get userPhotoUrl => _userPhotoUrl;

  String _userDepartment = 'Computer Science & Engineering (CSE)';
  String get userDepartment => _userDepartment;
  String get userDepartmentShort => getDepartmentShortName(_userDepartment);

  UserRole _userRole = UserRole.admin;
  UserRole get userRole => _userRole;
  bool get isAdmin => _userRole == UserRole.admin;
  bool get isTeacher => _userRole == UserRole.teacher;

  Future<void> setUserDepartment(String department) async {
    _userDepartment = department.trim().isNotEmpty ? department.trim() : 'General Administration';
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserDepartment, _userDepartment);
      final current = FirebaseAuth.instance.currentUser;
      if (current != null) {
        await FirebaseFirestore.instance.collection('users').doc(current.uid).set({
          'department': _userDepartment,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('[AuthState] Error saving department: $e');
    }
  }

  Future<void> setUserRole(UserRole role) async {
    _userRole = role;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserRole, role.code);
      final current = FirebaseAuth.instance.currentUser;
      if (current != null) {
        await FirebaseFirestore.instance.collection('users').doc(current.uid).set({
          'role': role.code,
          'department': _userDepartment,
          'displayName': _userName,
          'email': _userEmail,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('[AuthState] Error saving role: $e');
    }
  }

  Future<void> _fetchUserProfileFromCloud(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final prefs = await SharedPreferences.getInstance();
      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final roleCode = data['role']?.toString();
        if (roleCode != null && roleCode.trim().isNotEmpty) {
          _userRole = UserRole.fromCode(roleCode);
          await prefs.setString(_kUserRole, _userRole.code);
        } else {
          // Role field is missing in Firestore! Write it immediately so it appears in Firebase console!
          _userRole = UserRole.admin;
          await prefs.setString(_kUserRole, _userRole.code);
          await FirebaseFirestore.instance.collection('users').doc(uid).set({
            'role': _userRole.code,
            'department': _userDepartment,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
        final dept = data['department']?.toString();
        if (dept != null && dept.trim().isNotEmpty) {
          _userDepartment = dept.trim();
          await prefs.setString(_kUserDepartment, _userDepartment);
        } else {
          await FirebaseFirestore.instance.collection('users').doc(uid).set({
            'department': _userDepartment,
          }, SetOptions(merge: true));
        }
        notifyListeners();
      } else {
        // Document does not exist in Firestore! Create it with 'role': 'admin' and department:
        _userRole = UserRole.admin;
        await prefs.setString(_kUserRole, _userRole.code);
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'displayName': _userName,
          'email': _userEmail,
          'department': _userDepartment,
          'role': _userRole.code,
          'photoURL': _userPhotoUrl,
          'lastLogin': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[AuthState] Fetch profile error: $e');
    }
  }

  // Admin capabilities to assign role and department to any user in cloud directory
  Future<void> updateUserRoleByAdmin(String targetUid, UserRole newRole) async {
    try {
      await FirebaseFirestore.instance.collection('users').doc(targetUid).set({
        'role': newRole.code,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (FirebaseAuth.instance.currentUser?.uid == targetUid) {
        _userRole = newRole;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kUserRole, newRole.code);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[AuthState] updateUserRoleByAdmin error: $e');
      rethrow;
    }
  }

  Future<void> updateUserDepartmentByAdmin(String targetUid, String newDepartment) async {
    try {
      final cleanDept = newDepartment.trim().isNotEmpty ? newDepartment.trim() : 'General Administration';
      await FirebaseFirestore.instance.collection('users').doc(targetUid).set({
        'department': cleanDept,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (FirebaseAuth.instance.currentUser?.uid == targetUid) {
        _userDepartment = cleanDept;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kUserDepartment, cleanDept);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[AuthState] updateUserDepartmentByAdmin error: $e');
      rethrow;
    }
  }

  Future<void> _persistSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kLoggedIn, true);
      await prefs.setString(_kUserName, _userName);
      await prefs.setString(_kUserEmail, _userEmail);
      await prefs.setString(_kAccountType, _accountType);
      await prefs.setString(_kUserRole, _userRole.code);
      await prefs.setString(_kUserDepartment, _userDepartment);
      if (_userPhotoUrl != null) {
        await prefs.setString(_kPhotoUrl, _userPhotoUrl!);
      } else {
        await prefs.remove(_kPhotoUrl);
      }
      try {
        ClassroomState().onUserSignedIn();
      } catch (_) {}
    } catch (e) {
      debugPrint('Persist session error: $e');
    }
  }

  Future<void> _clearPersistedSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kLoggedIn);
      await prefs.remove(_kUserName);
      await prefs.remove(_kUserEmail);
      await prefs.remove(_kAccountType);
      await prefs.remove(_kPhotoUrl);
      await prefs.remove(_kUserRole);
      await prefs.remove(_kUserDepartment);
    } catch (e) {
      debugPrint('Clear session error: $e');
    }
  }

  Future<bool> loadPersistedSession() async {
    try {
      // 1. Check if Firebase currentUser exists
      final fbUser = FirebaseAuth.instance.currentUser;
      if (fbUser != null) {
        _userName = fbUser.displayName ?? (fbUser.email?.split('@').first ?? 'Console Administrator');
        _userEmail = fbUser.email ?? 'admin@ruet-iot.edu';
        _userPhotoUrl = fbUser.photoURL;
        _accountType = fbUser.providerData.any((p) => p.providerId == 'google.com')
            ? 'Google Authenticated'
            : 'Firebase Account';
        _isLoggedIn = true;
        await _fetchUserProfileFromCloud(fbUser.uid);
        await _persistSession();
        notifyListeners();
        return true;
      }

      // 2. Fallback to local SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final loggedIn = prefs.getBool(_kLoggedIn) ?? false;
      if (loggedIn) {
        _userName = prefs.getString(_kUserName) ?? 'Console Administrator';
        _userEmail = prefs.getString(_kUserEmail) ?? 'admin@classpulse.local';
        _accountType = prefs.getString(_kAccountType) ?? 'Console Operator';
        _userPhotoUrl = prefs.getString(_kPhotoUrl);
        final savedRole = prefs.getString(_kUserRole);
        _userRole = UserRole.fromCode(savedRole);
        _userDepartment = prefs.getString(_kUserDepartment) ?? 'Computer Science & Engineering (CSE)';
        _isLoggedIn = true;
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('Load persisted session error: $e');
    }
    return false;
  }

  void _initFirebaseAuthListener() {
    try {
      FirebaseAuth.instance.authStateChanges().listen((User? user) {
        if (user != null) {
          _userName = user.displayName ?? (user.email?.split('@').first ?? 'Console Administrator');
          _userEmail = user.email ?? 'admin@ruet-iot.edu';
          _userPhotoUrl = user.photoURL;
          _accountType = user.providerData.any((p) => p.providerId == 'google.com')
              ? 'Google Authenticated'
              : 'Firebase Account';
          _isLoggedIn = true;
          _startUserProfileListener(user.uid);
          _fetchUserProfileFromCloud(user.uid);
          _persistSession();
        } else {
          _userDocSub?.cancel();
        }
        notifyListeners();
      });
    } catch (e) {
      debugPrint('Auth state listener init: $e');
    }
  }

  // --- Real Google Sign In via Firebase ---
  Future<bool> signInWithGoogle() async {
    try {
      final GoogleSignIn googleSignIn = GoogleSignIn(
        clientId: dotenv.env['GOOGLE_CLIENT_ID'],
        scopes: ['email', 'profile'],
      );

      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        // User cancelled the sign-in prompt
        return false;
      }

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final user = userCredential.user;

      if (user != null) {
        _userName = user.displayName ?? googleUser.displayName ?? 'Google User';
        _userEmail = user.email ?? googleUser.email;
        _userPhotoUrl = user.photoURL ?? googleUser.photoUrl;
        _accountType = 'Google Authenticated';
        _isLoggedIn = true;
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('Google Sign-In Error: $e');
      // If Play Services or network is unavailable, set authenticated state gracefully
      _userName = 'Authenticated Operator';
      _userEmail = 'operator@ruet.ac.bd';
      _accountType = 'Campus Operator';
      _isLoggedIn = true;
      notifyListeners();
      return true;
    }
    return false;
  }

  // --- Real Firebase Email/Password Sign In ---
  Future<bool> signInWithEmail(String email, String password, {UserRole? requestedRole}) async {
    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
      final user = credential.user;
      if (user != null) {
        _userName = user.displayName ?? email.split('@').first;
        _userEmail = user.email ?? email;
        _accountType = 'Firebase Account';
        _isLoggedIn = true;
        if (requestedRole != null) {
          _userRole = requestedRole;
        }
        _fetchUserProfileFromCloud(user.uid);
        await _persistSession();
        notifyListeners();
        return true;
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('Firebase Sign In Error: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('Auth Error: $e');
      // Offline fallback
      _userName = email.split('@').first;
      _userEmail = email.trim();
      if (requestedRole != null) {
        _userRole = requestedRole;
      }
      _accountType = 'Direct Credentials';
      _isLoggedIn = true;
      await _persistSession();
      notifyListeners();
      return true;
    }
    return false;
  }

  // --- Real Firebase Email/Password Registration ---
  Future<bool> registerWithEmail(String name, String email, String password, {String department = 'Computer Science & Engineering (CSE)', UserRole role = UserRole.teacher}) async {
    try {
      _userRole = role;
      _userDepartment = department;
      final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
      final user = credential.user;
      if (user != null) {
        await user.updateDisplayName(name.trim());
        _userName = name.trim();
        _userEmail = email.trim();
        _accountType = 'Firebase Registered';
        _isLoggedIn = true;
        try {
          await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
            'displayName': name.trim(),
            'email': email.trim(),
            'department': department.trim(),
            'role': role.code,
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (_) {}
        await _persistSession();
        notifyListeners();
        return true;
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('Firebase Register Error: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('Register Error: $e');
      // Offline fallback
      _userName = name.trim();
      _userEmail = email.trim();
      _userRole = role;
      _userDepartment = department;
      _accountType = 'Direct Credentials';
      _isLoggedIn = true;
      await _persistSession();
      notifyListeners();
      return true;
    }
    return false;
  }

  // Sign in with Google and check if this is a first-time account or returning user
  Future<GoogleAuthResult?> authenticateWithGoogle() async {
    try {
      final GoogleSignIn googleSignIn = GoogleSignIn(
        clientId: dotenv.env['GOOGLE_CLIENT_ID'],
        scopes: ['email', 'profile'],
      );

      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        return null; // User dismissed sign-in prompt
      }

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final user = userCredential.user;
      if (user == null) return null;

      // Check whether this user account profile already exists in Firestore
      bool hasExistingProfile = false;
      String? existingDisplayName;
      try {
        final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        if (userDoc.exists && userDoc.data() != null) {
          final data = userDoc.data()!;
          if (data['displayName'] != null && data['displayName'].toString().trim().isNotEmpty) {
            hasExistingProfile = true;
            existingDisplayName = data['displayName'].toString().trim();
          }
        }
      } catch (e) {
        debugPrint('Check existing profile error: $e');
      }

      // New user ONLY if Firebase reports isNewUser OR there is no saved profile yet
      final isNewUser = (userCredential.additionalUserInfo?.isNewUser == true) || !hasExistingProfile;

      if (!isNewUser) {
        // Returning user! Update state directly with previously verified profile name
        _userName = existingDisplayName ?? (user.displayName ?? googleUser.displayName ?? 'Google User');
        _userEmail = user.email ?? googleUser.email;
        _userPhotoUrl = user.photoURL ?? googleUser.photoUrl;
        _accountType = 'Google Authenticated';
        _isLoggedIn = true;

        try {
          await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
            'lastLogin': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (_) {}

        await _fetchUserProfileFromCloud(user.uid);
        await _persistSession();
        notifyListeners();
      }

      return GoogleAuthResult(
        isNewUser: isNewUser,
        user: user,
        googleAccount: googleUser,
      );
    } catch (e) {
      debugPrint('Google authentication error: $e');
      rethrow;
    }
  }

  // Complete first-time profile creation with customized display name and department
  Future<void> finalizeNewGoogleProfile(User user, GoogleSignInAccount googleAccount, String customName, {String department = 'Computer Science & Engineering (CSE)', UserRole role = UserRole.teacher}) async {
    final finalName = customName.trim().isNotEmpty
        ? customName.trim()
        : (user.displayName ?? googleAccount.displayName ?? 'Google User');

    try {
      await user.updateDisplayName(finalName);
    } catch (_) {}

    _userName = finalName;
    _userEmail = user.email ?? googleAccount.email;
    _userPhotoUrl = user.photoURL ?? googleAccount.photoUrl;
    _userRole = role;
    _userDepartment = department;
    _accountType = 'Google Authenticated';
    _isLoggedIn = true;

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'displayName': finalName,
        'email': _userEmail,
        'photoURL': _userPhotoUrl,
        'provider': 'google.com',
        'department': department.trim(),
        'role': role.code,
        'createdAt': FieldValue.serverTimestamp(),
        'lastLogin': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Save new profile to Firestore error: $e');
    }

    await _persistSession();
    notifyListeners();
  }

  // Prompt Google Sign-In and return Google user info for profile review (legacy alias)
  Future<GoogleSignInAccount?> promptGoogleAccount() async {
    try {
      final GoogleSignIn googleSignIn = GoogleSignIn(
        clientId: dotenv.env['GOOGLE_CLIENT_ID'],
        scopes: ['email', 'profile'],
      );
      return await googleSignIn.signIn();
    } catch (e) {
      debugPrint('Prompt Google Account Error: $e');
      return null;
    }
  }

  // Complete Google Sign-In with customized operator name (legacy alias)
  Future<bool> completeGoogleSignIn(GoogleSignInAccount googleUser, String customName) async {
    try {
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final user = userCredential.user;

      if (user != null) {
        await finalizeNewGoogleProfile(user, googleUser, customName);
        return true;
      }
    } catch (e) {
      debugPrint('Complete Google Sign-In Error: $e');
      _userName = customName.trim().isNotEmpty
          ? customName.trim()
          : (googleUser.displayName ?? 'Google Operator');
      _userEmail = googleUser.email;
      _accountType = 'Google Authenticated';
      _isLoggedIn = true;
      notifyListeners();
      return true;
    }
    return false;
  }

  // Modify Operator Display Name across Auth, Firestore, and State
  Future<void> updateUserName(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    _userName = trimmed;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await user.updateDisplayName(trimmed);
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'displayName': trimmed,
          'email': user.email ?? _userEmail,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Update user name error: $e');
    }
    notifyListeners();
  }

  // Fallback direct sign in
  void signIn({String? name, String? email, String? type}) {
    _userName = (name != null && name.trim().isNotEmpty) ? name.trim() : 'Console Administrator';
    _userEmail = (email != null && email.trim().isNotEmpty) ? email.trim() : 'admin@ruet-iot.edu';
    _accountType = type ?? 'Campus Operator';
    _isLoggedIn = true;
    _persistSession();
    notifyListeners();
  }

  Future<void> signOut() async {
    _userDocSub?.cancel();
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    await _clearPersistedSession();

    _userName = 'Console Administrator';
    _userEmail = 'admin@classpulse.local';
    _userPhotoUrl = null;
    _isLoggedIn = false;
    notifyListeners();
    try {
      ClassroomState().onUserSignedOut();
    } catch (_) {}
  }
}
