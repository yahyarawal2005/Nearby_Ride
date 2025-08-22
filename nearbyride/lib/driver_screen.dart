// ignore_for_file: unused_field

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:nearbyride/loginpage.dart';

class DriverScreen extends StatefulWidget {
  const DriverScreen({super.key});

  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  String selectedType = 'car';
  bool routing = false;
  Timer? locationTimer;
  GoogleMapController? _mapController;
  LatLng? _currentPosition;
  BitmapDescriptor? _vehicleIcon;
  BitmapDescriptor? _userIcon; // user marker icon
  Marker? _driverMarker;
  Set<Marker> _otherDriverMarkers = {};
  Set<Marker> _userMarkers = {}; // new markers for users
  StreamSubscription? _otherDriversSubscription;
  StreamSubscription? _usersSubscription; // new subscription for users
  bool _isStartingRoute = false;

  Future<void> requestLocationPermission() async {
    final status = await Permission.location.request();
    if (status != PermissionStatus.granted) {
      throw Exception('Location permission denied');
    }
  }

  Future<void> getCurrentLocation() async {
    await requestLocationPermission();
    final position = await Geolocator.getCurrentPosition();
    setState(() {
      _currentPosition = LatLng(position.latitude, position.longitude);
    });
  }

  Future<BitmapDescriptor> getVehicleIcon(String type) async {
    String path = 'assets/icons/bus.png';
    if (type == 'car') path = 'assets/icons/car.png';
    if (type == 'rickshaw') path = 'assets/icons/rickshaw.png';

    final ByteData byteData = await rootBundle.load(path);
    final ui.Codec codec = await ui.instantiateImageCodec(
      byteData.buffer.asUint8List(),
      targetWidth: 150,
      targetHeight: 150,
    );
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    final ByteData? resizedByteData =
        await frameInfo.image.toByteData(format: ui.ImageByteFormat.png);

    if (resizedByteData == null) {
      return BitmapDescriptor.defaultMarker;
    }

    return BitmapDescriptor.fromBytes(resizedByteData.buffer.asUint8List());
  }

  Future<BitmapDescriptor> getUserIcon() async {
    final ByteData byteData = await rootBundle.load('assets/icons/user.png');
    final ui.Codec codec = await ui.instantiateImageCodec(
      byteData.buffer.asUint8List(),
      targetWidth: 120,
      targetHeight: 120,
    );
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    final ByteData? resizedByteData =
        await frameInfo.image.toByteData(format: ui.ImageByteFormat.png);
    if (resizedByteData == null) {
      return BitmapDescriptor.defaultMarker;
    }
    return BitmapDescriptor.fromBytes(resizedByteData.buffer.asUint8List());
  }

  Future<void> startRoute() async {
    setState(() {
      _isStartingRoute = true;
    });

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _isStartingRoute = false;
      });
      return;
    }

    try {
      await requestLocationPermission();
      final pos = await Geolocator.getCurrentPosition();

      _vehicleIcon = await getVehicleIcon(selectedType);

      await FirebaseFirestore.instance.collection('drivers').doc(user.uid).set({
        'email': user.email,
        'type': selectedType,
        'routing': true,
        'lat': pos.latitude,
        'lng': pos.longitude,
      }, SetOptions(merge: true));

      locationTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
        final position = await Geolocator.getCurrentPosition();
        FirebaseFirestore.instance.collection('drivers').doc(user.uid).update({
          'lat': position.latitude,
          'lng': position.longitude,
        });

        setState(() {
          _currentPosition = LatLng(position.latitude, position.longitude);
          _driverMarker = Marker(
            markerId: const MarkerId("driver"),
            position: _currentPosition!,
            icon: _vehicleIcon ?? BitmapDescriptor.defaultMarker,
            infoWindow: InfoWindow(title: selectedType.toUpperCase()),
          );
        });
      });

      setState(() {
        routing = true;
        _currentPosition = LatLng(pos.latitude, pos.longitude);
        _driverMarker = Marker(
          markerId: const MarkerId("driver"),
          position: _currentPosition!,
          icon: _vehicleIcon ?? BitmapDescriptor.defaultMarker,
          infoWindow: InfoWindow(title: selectedType.toUpperCase()),
        );
      });
    } finally {
      setState(() {
        _isStartingRoute = false;
      });
    }
  }

  Future<void> endRoute() async {
    locationTimer?.cancel();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await FirebaseFirestore.instance
        .collection('drivers')
        .doc(user.uid)
        .update({'routing': false});

    setState(() {
      routing = false;
      _driverMarker = null;
    });
  }

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  void dispose() {
    locationTimer?.cancel();
    _otherDriversSubscription?.cancel();
    _usersSubscription?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    getCurrentLocation();
    _listenForOtherDrivers();
    _listenForUsers();
    getUserIcon().then((icon) {
      setState(() {
        _userIcon = icon;
      });
    });
  }

  void _listenForOtherDrivers() {
    final currentUserUid = FirebaseAuth.instance.currentUser?.uid;
    _otherDriversSubscription = FirebaseFirestore.instance
        .collection('drivers')
        .where('routing', isEqualTo: true)
        .snapshots()
        .listen((snapshot) async {
      final Set<Marker> newMarkers = {};
      final currentDriverPosition = _currentPosition;
      if (currentDriverPosition == null) {
        setState(() {
          _otherDriverMarkers = {};
        });
        return;
      }
      for (var doc in snapshot.docs) {
        if (doc.id == currentUserUid) continue;
        final data = doc.data();
        final otherLat = data['lat'] as double?;
        final otherLng = data['lng'] as double?;
        final type = data['type'] as String?;
        final email = data['email'] as String?;
        if (otherLat != null && otherLng != null && type != null) {
          final distanceInMeters = Geolocator.distanceBetween(
            currentDriverPosition.latitude,
            currentDriverPosition.longitude,
            otherLat,
            otherLng,
          );
          if (distanceInMeters <= 1000) {
            final icon = await getVehicleIcon(type);
            newMarkers.add(
              Marker(
                markerId: MarkerId(doc.id),
                position: LatLng(otherLat, otherLng),
                icon: icon,
                infoWindow: InfoWindow(title: email ?? type.toUpperCase()),
              ),
            );
          }
        }
      }
      setState(() {
        _otherDriverMarkers = newMarkers;
      });
    });
  }

  void _listenForUsers() {
    _usersSubscription = FirebaseFirestore.instance
        .collection('users')
        .where('getfare', isEqualTo: true)
        .snapshots()
        .listen((snapshot) async {
      final Set<Marker> newUserMarkers = {};
      for (var doc in snapshot.docs) {
        final data = doc.data();
        final lat = data['lat'] as double?;
        final lng = data['lng'] as double?;
        final email = data['email'] as String?;
        if (lat != null && lng != null) {
          newUserMarkers.add(
            Marker(
              markerId: MarkerId("user_${doc.id}"),
              position: LatLng(lat, lng),
              icon: _userIcon ?? BitmapDescriptor.defaultMarker,
              infoWindow: InfoWindow(title: "User"),
            ),
          );
        }
      }
      setState(() {
        _userMarkers = newUserMarkers;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? 'Unknown';
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Driver Panel"),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: logout),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: height * 0.5,
            child: _currentPosition == null
                ? const Center(child: CircularProgressIndicator())
                : GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _currentPosition!,
                      zoom: 18,
                    ),
                    markers: {
                      if (_driverMarker != null) _driverMarker!,
                      ..._otherDriverMarkers,
                      ..._userMarkers, // add user markers
                    },
                    onMapCreated: (controller) {
                      _mapController = controller;
                    },
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                  ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Select Vehicle Type",
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87)),
                  const SizedBox(height: 10),
                  RadioListTile(
                    value: 'bus',
                    groupValue: selectedType,
                    onChanged: routing
                        ? null
                        : (val) => setState(() => selectedType = val as String),
                    title: const Text("Bus"),
                    activeColor: Colors.green,
                  ),
                  RadioListTile(
                    value: 'car',
                    groupValue: selectedType,
                    onChanged: routing
                        ? null
                        : (val) => setState(() => selectedType = val as String),
                    title: const Text("Car"),
                    activeColor: Colors.green,
                  ),
                  RadioListTile(
                    value: 'rickshaw',
                    groupValue: selectedType,
                    onChanged: routing
                        ? null
                        : (val) => setState(() => selectedType = val as String),
                    title: const Text("Rickshaw"),
                    activeColor: Colors.green,
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: _isStartingRoute
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                routing ? Icons.stop : Icons.play_arrow,
                                color: Colors.white,
                              ),
                        label: Text(
                          routing
                              ? "End Route"
                              : (_isStartingRoute
                                  ? "Starting Route..."
                                  : "Start Route"),
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.white,
                          ),
                        ),
                        onPressed: _isStartingRoute
                            ? null
                            : () => routing ? endRoute() : startRoute(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              routing ? Colors.redAccent : Colors.green,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
