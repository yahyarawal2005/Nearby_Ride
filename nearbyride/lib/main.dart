import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:nearbyride/loginpage.dart';

import 'driver_screen.dart';
import 'from_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nearby Ride',
      debugShowCheckedModeBanner: false,
      home: const LandingScreen(),
    );
  }
}

class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(), // auto updates
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }

        final user = snapshot.data;

        if (user == null) {
          return const LoginScreen(); // Not logged in
        }

        // Now check Firestore user profile
        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('drivers')
              .doc(user.uid)
              .snapshots(),
          builder: (context, docSnap) {
            if (docSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                  body: Center(child: CircularProgressIndicator()));
            }

            if (!docSnap.hasData || !docSnap.data!.exists) {
              return const FormScreen(); // No profile yet
            }

            final data = docSnap.data!.data() as Map<String, dynamic>;
            final isCompleted = data['profileCompleted'] == true;

            return isCompleted ? const DriverScreen() : const FormScreen();
          },
        );
      },
    );
  }
}
