package com.smartcampus.iot.smart_classroom_iot

import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.smartcampus.iot/system"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isWifiEnabled" -> {
                    try {
                        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        result.success(wifiManager.isWifiEnabled)
                    } catch (e: Exception) {
                        result.error("WIFI_STATE_ERROR", e.message, null)
                    }
                }
                "openWifiSettings" -> {
                    try {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            Intent(Settings.Panel.ACTION_WIFI)
                        } else {
                            Intent(Settings.ACTION_WIFI_SETTINGS)
                        }
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val fallback = Intent(Settings.ACTION_WIFI_SETTINGS)
                            fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(fallback)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("INTENT_ERROR", e2.message, null)
                        }
                    }
                }
                "toggleWifi" -> {
                    try {
                        val enable = call.argument<Boolean>("enabled") ?: true
                        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            // Android 10+ (API 29+) requires user confirmation via native panel
                            val intent = Intent(Settings.Panel.ACTION_WIFI)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } else {
                            @Suppress("DEPRECATION")
                            val success = wifiManager.setWifiEnabled(enable)
                            result.success(success)
                        }
                    } catch (e: Exception) {
                        result.error("TOGGLE_ERROR", e.message, null)
                    }
                }
                "openBluetoothSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INTENT_ERROR", e.message, null)
                    }
                }
                "isLocationEnabled" -> {
                    try {
                        val locationManager = applicationContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
                        val isGps = locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)
                        val isNetwork = locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
                        result.success(isGps || isNetwork)
                    } catch (e: Exception) {
                        result.error("LOCATION_STATE_ERROR", e.message, null)
                    }
                }
                "openLocationSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INTENT_ERROR", e.message, null)
                    }
                }
                "getWifiScanResults" -> {
                    try {
                        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        @Suppress("DEPRECATION")
                        wifiManager.startScan()
                        val scanResults = wifiManager.scanResults ?: emptyList()
                        val list = ArrayList<Map<String, Any>>()
                        for (scan in scanResults) {
                            val ssid = scan.SSID ?: ""
                            if (ssid.isEmpty()) continue
                            val item = HashMap<String, Any>()
                            item["ssid"] = ssid
                            item["bssid"] = scan.BSSID ?: ""
                            item["level"] = scan.level
                            item["frequency"] = if (scan.frequency > 4900) "5 GHz" else "2.4 GHz"
                            item["capabilities"] = when {
                                scan.capabilities.contains("WPA3") -> "WPA3 Secure"
                                scan.capabilities.contains("WPA2") -> "WPA2 Secure"
                                scan.capabilities.contains("WPA") -> "WPA Secure"
                                scan.capabilities.contains("WEP") -> "WEP"
                                else -> "Open Network"
                            }
                            list.add(item)
                        }
                        result.success(list)
                    } catch (e: Exception) {
                        result.error("SCAN_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
