import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/classroom.dart';
import '../models/device.dart';

class FirestoreService {
  static final FirestoreService _instance = FirestoreService._internal();
  factory FirestoreService() => _instance;

  FirestoreService._internal() {
    _enablePersistence();
  }

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Active sync debouncers per classroom to prevent hammering Firebase
  final Map<String, Timer> _syncDebouncers = {};

  void _enablePersistence() {
    try {
      _firestore.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );
      debugPrint('[FirestoreService] Offline cache persistence initialized (UNLIMITED).');
    } catch (e) {
      debugPrint('[FirestoreService] Settings configuration notice: $e');
    }
  }

  CollectionReference<Map<String, dynamic>> get _classroomsRef =>
      _firestore.collection('classrooms');

  // Direct one-shot retrieval of all classrooms from Firestore
  Future<List<Classroom>?> fetchClassroomsOnce() async {
    try {
      final snapshot = await _classroomsRef.get(const GetOptions(source: Source.serverAndCache));
      return snapshot.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = doc.id;
        return Classroom.fromMap(data);
      }).toList();
    } catch (e) {
      debugPrint('[FirestoreService] fetchClassroomsOnce error: $e');
      return null;
    }
  }

  // Real-time stream of all classrooms and their configured devices
  Stream<List<Classroom>> getClassroomsStream() {
    return _classroomsRef.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = doc.id;
        return Classroom.fromMap(data);
      }).toList();
    });
  }

  // Rapid debounced cloud sync: batches rapid user interactions into a fast write (150ms)
  void queueClassroomSync(Classroom room, {Duration delay = const Duration(milliseconds: 150)}) {
    _syncDebouncers[room.id]?.cancel();
    _syncDebouncers[room.id] = Timer(delay, () {
      syncClassroom(room);
    });
  }

  // Push or update classroom document in Firestore directly (stores device types, pins, metadata; EXCLUDES live power state)
  Future<void> syncClassroom(Classroom room) async {
    _syncDebouncers[room.id]?.cancel();
    try {
      final docRef = _classroomsRef.doc(room.id);
      final map = room.toFirestoreMap();
      map['updatedAt'] = FieldValue.serverTimestamp();
      await docRef.set(map, SetOptions(merge: true));
      debugPrint('[FirestoreService] Classroom ${room.roomNumber} metadata synced to cloud (power states excluded).');
    } catch (e) {
      debugPrint('[FirestoreService] syncClassroom error (offline/rules): $e');
    }
  }

  // Sync full device state & configuration snapshot at class intervals (3 intervals per 50-minute class session)
  // Ensures incoming teachers automatically sync to live device states and hardware configurations.
  Future<void> syncClassroomStateAndConfig(Classroom room, {int interval = 1}) async {
    try {
      final docRef = _classroomsRef.doc(room.id);
      final List<Map<String, dynamic>> stateList =
          room.devices.map((d) => d.toStateAndConfigMap()).toList();

      await docRef.set({
        'lastIntervalSync': FieldValue.serverTimestamp(),
        'classSyncInterval': interval, // 1, 2, or 3
        'devicesState': stateList,
      }, SetOptions(merge: true));

      debugPrint('[FirestoreService] Class session interval $interval/3 state & config snapshot synced for room ${room.roomNumber}');
    } catch (e) {
      debugPrint('[FirestoreService] syncClassroomStateAndConfig error: $e');
    }
  }

  // Delete classroom document from Firestore
  Future<void> deleteClassroom(String roomId) async {
    _syncDebouncers[roomId]?.cancel();
    try {
      await _classroomsRef.doc(roomId).delete();
    } catch (e) {
      debugPrint('Firestore deleteClassroom error: $e');
    }
  }

  // Wipe all classroom documents from Firestore
  Future<void> wipeAllClassrooms() async {
    try {
      final snapshot = await _classroomsRef.get();
      if (snapshot.docs.isEmpty) {
        debugPrint('Firestore: no classroom documents to wipe.');
        return;
      }
      // Firestore batch supports up to 500 writes
      final docs = snapshot.docs;
      for (var i = 0; i < docs.length; i += 400) {
        final end = (i + 400 < docs.length) ? i + 400 : docs.length;
        final chunk = docs.sublist(i, end);
        final batch = _firestore.batch();
        for (final doc in chunk) {
          batch.delete(doc.reference);
        }
        await batch.commit();
      }
      debugPrint('Firestore: successfully wiped ${docs.length} classroom documents.');
    } catch (e) {
      debugPrint('Firestore wipeAllClassrooms error: $e');
    }
  }

  // Update specific device state (e.g. toggle relay, change speed, adjust temp)
  Future<void> updateDeviceState(String roomId, ClassroomDevice device) async {
    try {
      final docRef = _classroomsRef.doc(roomId);
      final snapshot = await docRef.get();
      if (!snapshot.exists || snapshot.data() == null) return;

      final data = snapshot.data()!;
      final List<dynamic> devices = List.from(data['devices'] ?? []);
      final idx = devices.indexWhere((d) => d['id'] == device.id);

      final deviceMap = {
        'id': device.id,
        'name': device.name,
        'type': device.type.name,
        'statusDescription': device.statusDescription,
        'isOn': device.isOn,
        'zone': device.zone,
        'relayChannel': device.relayChannel,
        'hardwareModel': device.hardwareModel,
        'macAddress': device.macAddress,
        'protocol': device.protocol,
        'temperature': device.temperature,
        'hvacMode': device.hvacMode,
        'fanSpeed': device.fanSpeed,
        'fanReverse': device.fanReverse,
        'brightness': device.brightness,
      };

      if (idx >= 0) {
        devices[idx] = deviceMap;
      } else {
        devices.add(deviceMap);
      }

      await docRef.update({
        'devices': devices,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Firestore updateDeviceState error: $e');
    }
  }

  // Realtime stream for Security Emergency PIN (saved strictly on Firestore)
  Stream<DocumentSnapshot<Map<String, dynamic>>> getSecurityConfigStream() {
    return _firestore.collection('security').doc('emergency_config').snapshots();
  }

  // Save Emergency PIN exclusively to Firestore
  Future<void> saveEmergencyPin(String pin, bool isEnabled) async {
    try {
      await _firestore.collection('security').doc('emergency_config').set({
        'emergencyPin': pin,
        'isEmergencyPinEnabled': isEnabled,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Firestore saveEmergencyPin error: $e');
    }
  }
}
