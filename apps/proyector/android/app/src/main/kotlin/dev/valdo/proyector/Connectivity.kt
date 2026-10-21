package dev.valdo.proyector

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.net.wifi.WifiManager

// Wi-Fi (nombre e intensidad) y dispositivos Bluetooth conectados, para el inicio.
// El nombre de la red requiere ACCESS_FINE_LOCATION y BLUETOOTH_CONNECT (se
// conceden por adb con `pm grant`). El Bluetooth clásico (bocinas, controles)
// no expone intensidad de señal en Android: de esos solo hay nombre y tipo.
object Connectivity {
    // HID host (controles, teclados) no tiene constante pública; su valor es 4.
    private val profiles = intArrayOf(BluetoothProfile.A2DP, BluetoothProfile.HEADSET, 4)
    private val proxies = mutableMapOf<Int, BluetoothProfile>()

    fun init(context: Context) {
        val adapter = adapter(context) ?: return
        for (p in profiles) {
            try {
                adapter.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
                    override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                        proxies[profile] = proxy
                    }

                    override fun onServiceDisconnected(profile: Int) {
                        proxies.remove(profile)
                    }
                }, p)
            } catch (_: Exception) {
                // Perfil no disponible en este equipo.
            }
        }
    }

    @Suppress("DEPRECATION")
    fun snapshot(context: Context): Map<String, Any?> {
        val wm = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val info = try { wm.connectionInfo } catch (_: Exception) { null }
        val connected = info != null && info.networkId != -1
        val ssid = info?.ssid?.trim('"')?.takeUnless { it.isBlank() || it == "<unknown ssid>" }
        val rssi = info?.rssi ?: -127
        val wifi = if (!connected) null else mapOf(
            "ssid" to ssid,
            "rssi" to rssi,
            "level" to WifiManager.calculateSignalLevel(rssi, 5), // 0..4
        )

        val devices = linkedMapOf<String, Map<String, Any?>>()
        for ((profile, proxy) in proxies) {
            val list = try { proxy.connectedDevices } catch (_: SecurityException) { emptyList<BluetoothDevice>() }
            for (d in list) {
                val name = try { d.name } catch (_: SecurityException) { null } ?: d.address
                devices[d.address] = mapOf(
                    "name" to name,
                    "kind" to when (profile) {
                        BluetoothProfile.A2DP -> "audio"
                        BluetoothProfile.HEADSET -> "audio"
                        else -> "control"
                    },
                )
            }
        }
        return mapOf("wifi" to wifi, "bluetooth" to devices.values.toList())
    }

    private fun adapter(context: Context): BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?)?.adapter
}
