import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/app_logo.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/route_transitions.dart';
import '../widgets/auth_loading_overlay.dart';
import '../models/user_role.dart';
import '../state/auth_state.dart';
import 'dashboard_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = true;
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _isGoogleLoading = false;
  String _selectedDepartment = kCampusDepartments.first;

  // Controllers start clean with NO pre-filled mock data
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (AuthState().isLoggedIn || FirebaseAuth.instance.currentUser != null) {
        Navigator.of(context).pushReplacement(
          Cube3DPageRoute(page: const DashboardScreen()),
        );
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitAuth() async {
    FocusScope.of(context).unfocus();
    HapticFeedback.mediumImpact();
    final email = _emailController.text.trim();
    final pwd = _passwordController.text.trim();
    final name = _nameController.text.trim();

    if (!_isLogin && name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your full name.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (email.isEmpty || pwd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your credentials to proceed.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _isGoogleLoading = false;
    });

    try {
      if (_isLogin) {
        await AuthState().signInWithEmail(email, pwd);
      } else {
        await AuthState().registerWithEmail(name, email, pwd, department: _selectedDepartment);
      }

      if (!mounted) return;
      // Provide cybernetic authenticating / provisioning telemetry animation
      await Future.delayed(const Duration(milliseconds: 1800));
      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        Cube3DPageRoute(page: const DashboardScreen()),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll("Exception: ", "")),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _signInWithGoogle() async {
    FocusScope.of(context).unfocus();
    HapticFeedback.mediumImpact();

    setState(() {
      _isLoading = true;
      _isGoogleLoading = true;
    });

    try {
      final result = await AuthState().authenticateWithGoogle();
      if (result == null) {
        // User cancelled Google sign-in prompt
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isGoogleLoading = false;
          });
        }
        return;
      }

      if (!result.isNewUser) {
        // Returning user with an existing account: Do NOT show custom form
        await Future.delayed(const Duration(milliseconds: 1400));
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          Cube3DPageRoute(page: const DashboardScreen()),
        );
      } else {
        // First-time user with no existing account: show custom form to confirm display name
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isGoogleLoading = false;
          });
          _showGoogleProfileConfirmationDialog(result.user, result.googleAccount);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isGoogleLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Google Sign-In: ${e.toString().replaceAll("Exception: ", "")}'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  void _showGoogleProfileConfirmationDialog(User user, GoogleSignInAccount googleAccount) {
    final nameController = TextEditingController(
      text: user.displayName ?? googleAccount.displayName ?? '',
    );
    String dialogDept = _selectedDepartment;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: AppColors.surfaceContainerLowest,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                        ),
                        child: _buildGoogleIcon(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Google Identity Verified',
                              style: AppTypography.headlineSm(fontSize: 16),
                            ),
                            Text(
                              'Confirm operator name & academic department',
                              style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Email from Google Account (Locked / Read-Only)
                  Text(
                    'GOOGLE ACCOUNT EMAIL',
                    style: AppTypography.labelSm(color: AppColors.outline).copyWith(fontSize: 9),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: AppColors.surfaceContainerLowest,
                      border: Border.all(color: AppColors.onlineMint.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, size: 16, color: AppColors.onlineMint),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            googleAccount.email,
                            style: AppTypography.bodyMd(color: AppColors.onSurface)
                                .copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: AppColors.onlineMint.withValues(alpha: 0.15),
                          ),
                          child: Text(
                            'VERIFIED',
                            style: AppTypography.labelSm(color: AppColors.onlineMint).copyWith(fontSize: 8.5),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Custom Operator Name Field (Editable)
                  Text(
                    'OPERATOR FULL NAME',
                    style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontSize: 9),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: AppColors.surfaceContainerLowest,
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.5)),
                    ),
                    child: TextField(
                      controller: nameController,
                      autofocus: true,
                      style: AppTypography.bodyMd(color: AppColors.onSurface),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.badge_outlined, size: 18, color: AppColors.primary),
                        hintText: 'Enter your preferred display name',
                        hintStyle: TextStyle(color: AppColors.outline),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Academic Department in Google Modal
                  Text(
                    'CAMPUS / ACADEMIC DEPARTMENT',
                    style: AppTypography.labelSm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 9),
                  ),
                  const SizedBox(height: 6),
                  _buildDepartmentSelector(
                    selectedDepartment: dialogDept,
                    onSelected: (val) => setSheetState(() => dialogDept = val),
                  ),

                  const SizedBox(height: 24),

                  // Confirm Button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: AppColors.onPrimaryFixed,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        final chosenName = nameController.text.trim();
                        if (chosenName.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter an operator name')),
                          );
                          return;
                        }
                        Navigator.pop(ctx);

                        setState(() {
                          _isLoading = true;
                          _isGoogleLoading = true;
                        });

                        await AuthState().finalizeNewGoogleProfile(user, googleAccount, chosenName, department: dialogDept);

                        await Future.delayed(const Duration(milliseconds: 1600));
                        if (!mounted) return;
                        Navigator.of(context).pushReplacement(
                          Cube3DPageRoute(page: const DashboardScreen()),
                        );
                      },
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Confirm & Enter Console',
                            style: AppTypography.headlineSm(
                              color: AppColors.surfaceContainerLowest,
                            ).copyWith(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_forward, size: 16, color: AppColors.surfaceContainerLowest),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showForgotPasswordDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          title: Text(
            'Reset Hardware Token',
            style: AppTypography.headlineSm(color: AppColors.primary),
          ),
          content: Text(
            'Enter your institutional email address to receive an access token recovery link.',
            style: AppTypography.bodyMd(color: AppColors.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'DISMISS',
                style: AppTypography.labelLg(color: AppColors.primary),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 32,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                      const SizedBox(height: 6),

                      // Pulsing Hardware Status Beacon
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: AppColors.surfaceContainerLow,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const PulsingBeacon(size: 6, color: AppColors.primary),
                            const SizedBox(width: 8),
                            Text(
                              'NODE 01 // GATE ONLINE',
                              style: AppTypography.labelSm(
                                color: AppColors.primary,
                              ).copyWith(fontSize: 9, letterSpacing: 1.2),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ClassPulse Logo + Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const ClassPulseLogo(size: 34),
                          const SizedBox(width: 10),
                          Text(
                            'ClassPulse IoT',
                            style: AppTypography.headlineMd(
                              color: AppColors.primary,
                            ).copyWith(fontSize: 19),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Connected Classroom Infrastructure',
                        style: AppTypography.bodySm(
                          color: AppColors.onSurfaceVariant,
                        ).copyWith(fontSize: 11),
                      ),

                      const SizedBox(height: 20),

                      // Segmented Tab Switcher (Unified Recessed Channel)
                      Container(
                        height: 42,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: const Color(0xFF070B14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        padding: const EdgeInsets.all(3),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() => _isLogin = true);
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 140),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(9),
                                    color: _isLogin
                                        ? AppColors.surfaceContainer
                                        : Colors.transparent,
                                    boxShadow: _isLogin
                                        ? [
                                            BoxShadow(
                                              color: AppColors.primary
                                                  .withValues(alpha: 0.2),
                                              blurRadius: 12,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Text(
                                    'Log In',
                                    style: AppTypography.headlineSm(
                                      color: _isLogin
                                          ? AppColors.primary
                                          : AppColors.onSurfaceVariant,
                                    ).copyWith(fontSize: 13),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() => _isLogin = false);
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 140),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(9),
                                    color: !_isLogin
                                        ? AppColors.surfaceContainer
                                        : Colors.transparent,
                                    boxShadow: !_isLogin
                                        ? [
                                            BoxShadow(
                                              color: AppColors.primary
                                                  .withValues(alpha: 0.2),
                                              blurRadius: 12,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Text(
                                    'Sign Up',
                                    style: AppTypography.headlineSm(
                                      color: !_isLogin
                                          ? AppColors.primary
                                          : AppColors.onSurfaceVariant,
                                    ).copyWith(fontSize: 13),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Glassmorphic Auth Form Card
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: AppColors.surfaceContainer.withValues(alpha: 0.65),
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.2),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.08),
                              blurRadius: 20,
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Educator Name (Only in Sign Up)
                            if (!_isLogin) ...[
                              Text(
                                'EDUCATOR / ADMIN NAME',
                                style: AppTypography.labelSm(
                                  color: AppColors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 6),
                              _buildTextField(
                                controller: _nameController,
                                icon: Icons.badge_outlined,
                                hint: 'Enter your full name',
                              ),
                              const SizedBox(height: 14),
                            ],

                            // Campus Email
                            Text(
                              'CAMPUS / INSTITUTIONAL EMAIL',
                              style: AppTypography.labelSm(
                                color: AppColors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 6),
                            _buildTextField(
                              controller: _emailController,
                              icon: Icons.alternate_email,
                              hint: 'Enter your institutional email',
                              keyboardType: TextInputType.emailAddress,
                            ),
                            const SizedBox(height: 14),

                            // Password
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Flexible(
                                  child: Text(
                                    'ACCESS TOKEN / PASSWORD',
                                    style: AppTypography.labelSm(
                                      color: AppColors.onSurfaceVariant,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (_isLogin) ...[
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: _showForgotPasswordDialog,
                                    child: Text(
                                      'Forgot Password?',
                                      style: AppTypography.labelSm(
                                        color: AppColors.primaryFixedDim,
                                      ).copyWith(fontSize: 9),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 6),
                            _buildTextField(
                              controller: _passwordController,
                              icon: Icons.vpn_key_outlined,
                              hint: 'Enter your access token',
                              isPassword: true,
                              obscureText: _obscurePassword,
                              onToggleVisibility: () {
                                setState(() {
                                  _obscurePassword = !_obscurePassword;
                                });
                              },
                            ),

                            if (!_isLogin) ...[
                              const SizedBox(height: 14),
                              Text(
                                'CAMPUS / ACADEMIC DEPARTMENT',
                                style: AppTypography.labelSm(
                                  color: AppColors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 6),
                              _buildDepartmentSelector(
                                selectedDepartment: _selectedDepartment,
                                onSelected: (val) => setState(() => _selectedDepartment = val),
                              ),
                            ],

                            const SizedBox(height: 20),

                            // Submit CTA Button
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: AppColors.onPrimaryFixed,
                                  elevation: 4,
                                  shadowColor: AppColors.primary.withValues(alpha: 0.4),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onPressed: _isLoading ? null : _submitAuth,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      _isLogin
                                          ? 'Sign In to Campus Console'
                                          : 'Create Account & Join Campus',
                                      style: AppTypography.headlineSm(
                                        color: AppColors.surfaceContainerLowest,
                                      ).copyWith(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(
                                      Icons.arrow_forward,
                                      size: 16,
                                      color: AppColors.surfaceContainerLowest,
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(height: 14),

                            // SSO Divider
                            Row(
                              children: [
                                Expanded(
                                  child: Divider(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  child: Text(
                                    'OR SIGN IN WITH',
                                    style: AppTypography.labelSm(
                                      color: AppColors.outline,
                                    ).copyWith(fontSize: 9),
                                  ),
                                ),
                                Expanded(
                                  child: Divider(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 14),

                            // Google Login Button
                            SizedBox(
                              width: double.infinity,
                              height: 44,
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: AppColors.surfaceContainerLow,
                                  foregroundColor: AppColors.onSurface,
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.12),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onPressed: _isLoading ? null : _signInWithGoogle,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _buildGoogleIcon(),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Sign in with Google',
                                      style: AppTypography.bodySm(
                                        color: AppColors.onSurface,
                                      ).copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const Spacer(),
                      const SizedBox(height: 16),

                      // Bottom Hint Toggle
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            _isLogin
                                ? "Don't have hardware credentials?"
                                : 'Already authorized?',
                            style: AppTypography.bodySm(
                              color: AppColors.onSurfaceVariant,
                            ).copyWith(fontSize: 12),
                          ),
                          GestureDetector(
                            onTap: () {
                              setState(() => _isLogin = !_isLogin);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              child: Text(
                                _isLogin ? 'Sign Up' : 'Log In',
                                style: AppTypography.bodySm(
                                  color: AppColors.primary,
                                ).copyWith(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // Version Watermark
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            size: 11,
                            color: AppColors.outline,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'Classroom IoT Access System • v2.4',
                            style: AppTypography.labelSm(
                              color: AppColors.outline,
                            ).copyWith(fontSize: 9),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      if (_isLoading)
        AuthLoadingOverlay(
          isLogin: _isLogin,
          title: _isGoogleLoading
              ? 'GOOGLE OAUTH 2.0 HANDSHAKE'
              : (_isLogin ? 'VERIFYING CREDENTIALS' : 'PROVISIONING IDENTITY'),
        ),
    ],
  ),
);
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required IconData icon,
    required String hint,
    bool isPassword = false,
    bool obscureText = false,
    VoidCallback? onToggleVisibility,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.1),
        ),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: isPassword ? obscureText : false,
        style: AppTypography.bodyMd(color: AppColors.onSurface).copyWith(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
          prefixIcon: Icon(
            icon,
            size: 16,
            color: AppColors.outline,
          ),
          suffixIcon: isPassword
              ? IconButton(
                  icon: Icon(
                    obscureText
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 16,
                    color: AppColors.outline,
                  ),
                  onPressed: onToggleVisibility,
                )
              : null,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildDepartmentSelector({
    required String selectedDepartment,
    required ValueChanged<String> onSelected,
  }) {
    return GestureDetector(
      onTap: () => _showDepartmentPicker(context, selectedDepartment, onSelected),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.domain_rounded, size: 16, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                selectedDepartment,
                style: AppTypography.bodyMd(color: AppColors.onSurface).copyWith(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down_rounded, size: 22, color: AppColors.outline),
          ],
        ),
      ),
    );
  }

  void _showDepartmentPicker(
    BuildContext pickerContext,
    String currentDept,
    ValueChanged<String> onSelected,
  ) {
    showModalBottomSheet(
      context: pickerContext,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (sheetCtx, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.domain_rounded, color: AppColors.primary, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        'Select Academic Department',
                        style: AppTypography.headlineSm(fontSize: 15),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: kCampusDepartments.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (context, index) {
                      final dept = kCampusDepartments[index];
                      final isSelected = dept == currentDept;
                      return ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        tileColor: isSelected ? AppColors.primary.withValues(alpha: 0.12) : null,
                        leading: Icon(
                          isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                          size: 18,
                          color: isSelected ? AppColors.primary : AppColors.outline,
                        ),
                        title: Text(
                          dept,
                          style: AppTypography.bodySm(
                            color: isSelected ? AppColors.primary : AppColors.onSurface,
                          ).copyWith(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
                        ),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onSelected(dept);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildGoogleIcon() {
    return SizedBox(
      width: 18,
      height: 18,
      child: CustomPaint(
        painter: _GoogleIconPainter(),
      ),
    );
  }
}

class _GoogleIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final center = Offset(w / 2, h / 2);
    final radius = w * 0.44;
    final strokeWidth = w * 0.20;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final paintBlue = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    final paintGreen = Paint()
      ..color = const Color(0xFF34A853)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    final paintYellow = Paint()
      ..color = const Color(0xFFFBBC05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    final paintRed = Paint()
      ..color = const Color(0xFFEA4335)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    // Google multi-colored arcs
    canvas.drawArc(rect, -0.4, 1.4, false, paintBlue);
    canvas.drawArc(rect, 1.0, 1.5, false, paintGreen);
    canvas.drawArc(rect, 2.5, 1.2, false, paintYellow);
    canvas.drawArc(rect, 3.7, 1.4, false, paintRed);

    // Blue horizontal bar
    final barPaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(w * 0.46, h * 0.40, w * 0.48, strokeWidth),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
