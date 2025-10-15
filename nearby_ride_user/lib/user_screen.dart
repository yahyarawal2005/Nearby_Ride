import 'dart:async';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'login_page.dart';
import 'package:url_launcher/url_launcher.dart';

class UserScreen extends StatefulWidget {
  const UserScreen({Key? key}) : super(key: key);

  @override
  State<UserScreen> createState() => UserScreenState();
}

class UserScreenState extends State<UserScreen> {
  GoogleMapController? _mapController;
  LatLng? _currentPosition;
  Map<String, Marker> _markers = {};
  bool isSharing = false;
  Timer? _userUpdateTimer;
  StreamSubscription? _driversSubscription;

  String _userName = ""; // store user name
  Set<String> _selectedVehicleTypes = {};

  @override
  void initState() {
    super.initState();
    _fetchUserName();
    _getCurrentLocation();
    _listenToDrivers();
    _listenToUserLocation();
  }

  Future<void> _fetchUserName() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // Try to get name from Firestore if stored
      DocumentSnapshot userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      if (userDoc.exists && userDoc['name'] != null) {
        setState(() {
          _userName = userDoc['name'];
        });
      } else {
        // fallback to Firebase Auth displayName
        setState(() {
          _userName = user.displayName ?? "User";
        });
      }
    }
  }

  @override
  void dispose() {
    _userUpdateTimer?.cancel();
    _driversSubscription?.cancel();
    super.dispose();
  }

  Future<BitmapDescriptor> getVehicleIcon(String type) async {
    String path = 'assets/icons/bus.png';
    if (type == 'car') path = 'assets/icons/car.png';
    if (type == 'rickshaw' || type == 'auto')
      path = 'assets/icons/rickshaw.png';
    if (type == 'user') path = 'assets/icons/user.png';

    try {
      final ByteData byteData = await rootBundle.load(path);
      final ui.Codec codec = await ui.instantiateImageCodec(
        byteData.buffer.asUint8List(),
        targetWidth: 150,
        targetHeight: 150,
      );
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ByteData? resizedByteData =
          await frameInfo.image.toByteData(format: ui.ImageByteFormat.png);

      if (resizedByteData == null) return BitmapDescriptor.defaultMarker;
      return BitmapDescriptor.fromBytes(resizedByteData.buffer.asUint8List());
    } catch (e) {
      print("Error loading icon for type $type: $e");
      return BitmapDescriptor.defaultMarker;
    }
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);

    setState(() {
      _currentPosition = LatLng(position.latitude, position.longitude);
    });

    if (!isSharing) {
      BitmapDescriptor userIcon = await getVehicleIcon("user");
      _markers["user"] = Marker(
        markerId: const MarkerId("user"),
        position: _currentPosition!,
        icon: userIcon,
      );
    }

    _mapController
        ?.animateCamera(CameraUpdate.newLatLngZoom(_currentPosition!, 15));
  }

  Future<void> _startSharingLocation() async {
    if (_currentPosition == null) await _getCurrentLocation();
    if (_currentPosition == null) return;

    String uid = FirebaseAuth.instance.currentUser!.uid;

    await FirebaseFirestore.instance.collection("users").doc(uid).set({
      "lat": _currentPosition!.latitude,
      "lng": _currentPosition!.longitude,
      "getfare": true,
      "timestamp": FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    _userUpdateTimer =
        Timer.periodic(const Duration(seconds: 10), (timer) async {
      Position pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);

      setState(() {
        _currentPosition = LatLng(pos.latitude, pos.longitude);
      });

      await FirebaseFirestore.instance.collection("users").doc(uid).update({
        "lat": pos.latitude,
        "lng": pos.longitude,
        "getfare": true,
        "timestamp": FieldValue.serverTimestamp(),
      });
    });

    setState(() {
      isSharing = true;
    });
  }

  Future<void> _stopSharingLocation() async {
    String uid = FirebaseAuth.instance.currentUser!.uid;
    await FirebaseFirestore.instance.collection("users").doc(uid).update({
      "getfare": false,
    });
    _userUpdateTimer?.cancel();
    setState(() {
      isSharing = false;
    });
  }

  Widget _buildVehicleCheckbox(String title, String vehicleType) {
    return Column(
      children: [
        Checkbox(
          value: _selectedVehicleTypes.contains(vehicleType),
          onChanged: (bool? value) {
            setState(() {
              if (value == true) {
                _selectedVehicleTypes.add(vehicleType);
              } else {
                _selectedVehicleTypes.remove(vehicleType);
              }
            });
            _listenToDrivers(); // Re-filter drivers based on selection
          },
        ),
        Text(title),
      ],
    );
  }

  void _listenToDrivers() {
    _driversSubscription?.cancel();

    _driversSubscription = FirebaseFirestore.instance
        .collection("drivers")
        .where("routing", isEqualTo: true)
        .snapshots()
        .listen((snapshot) async {
      if (_currentPosition == null) return;

      Map<String, Marker> driverMarkers = {};

      for (var doc in snapshot.docs) {
        final data = doc.data();
        final driverLat = data["lat"];
        final driverLng = data["lng"];
        final type = (data["type"] ?? "").toString().toLowerCase();
        final name = data["name"] ?? "Driver";
        final phone = data["phone"] ?? "N/A";

        if (driverLat == null || driverLng == null) continue;

        // Filter based on selected vehicle types
        if (_selectedVehicleTypes.isNotEmpty &&
            !_selectedVehicleTypes.contains(type)) {
          continue;
        }

        double distanceInMeters = Geolocator.distanceBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          driverLat,
          driverLng,
        );

        if (distanceInMeters <= 5000) {
          BitmapDescriptor icon = await getVehicleIcon(type);

          driverMarkers["driver_${doc.id}"] = Marker(
            markerId: MarkerId("driver_${doc.id}"),
            position: LatLng(driverLat, driverLng),
            icon: icon,
            onTap: () {
              _showDriverBottomSheet(name, phone, distanceInMeters);
            },
          );
        }
      }

      setState(() {
        _markers.removeWhere((key, value) => key.startsWith("driver_"));
        _markers.addAll(driverMarkers);
      });
    });
  }

  void _listenToUserLocation() {
    String uid = FirebaseAuth.instance.currentUser!.uid;

    FirebaseFirestore.instance
        .collection("users")
        .doc(uid)
        .snapshots()
        .listen((doc) async {
      if (!doc.exists) return;
      final data = doc.data()!;
      if (data["getfare"] == true) {
        final userLat = data["lat"];
        final userLng = data["lng"];

        final marker = Marker(
          markerId: const MarkerId("user"),
          position: LatLng(userLat, userLng),
          icon: await getVehicleIcon("user"),
        );

        setState(() {
          _markers["user"] = marker;
        });
      } else {
        setState(() {
          _markers.remove("user");
        });
      }
    });
  }

  Future<void> _showDriverBottomSheet(
      String name, String phone, double distance) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text("Distance: ${(distance / 1000).toStringAsFixed(1)} km",
                  style: const TextStyle(color: Colors.grey)),
              const Divider(height: 24, thickness: 1.5),
              Row(
                children: [
                  const Icon(Icons.phone, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(phone, style: const TextStyle(fontSize: 16))),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      backgroundColor: Colors.blue,
                    ),
                    onPressed: () async {
                      final Uri url = Uri(scheme: 'tel', path: phone);
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url);
                      }
                    },
                    child: const Text(
                      "Call",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          "Welcome $_userName",
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: _logout,
          ),
        ],
        backgroundColor: Colors.blue.shade700,
      ),
      body: _currentPosition == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    reverse: true,
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: GoogleMap(
                                initialCameraPosition: CameraPosition(
                                  target: _currentPosition!,
                                  zoom: 20,
                                ),
                                markers: Set<Marker>.of(_markers.values),
                                onMapCreated: (controller) =>
                                    _mapController = controller,
                                zoomControlsEnabled: true,
                                compassEnabled: true,
                                myLocationButtonEnabled: true,
                                myLocationEnabled: true,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0, vertical: 8.0),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  _buildVehicleCheckbox("Car", "car"),
                                  _buildVehicleCheckbox("Bus", "bus"),
                                  _buildVehicleCheckbox(
                                      "Autorickshaw", "rickshaw"),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isSharing
                                        ? Colors.red.shade700
                                        : Colors.blue.shade700,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 16),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    elevation: 6,
                                  ),
                                  onPressed: isSharing
                                      ? _stopSharingLocation
                                      : _startSharingLocation,
                                  child: Text(
                                    isSharing
                                        ? "Stop Sharing Location"
                                        : "Get Fare",
                                    style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
