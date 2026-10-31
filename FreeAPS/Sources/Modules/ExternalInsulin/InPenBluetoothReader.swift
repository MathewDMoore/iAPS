import Combine
import CoreBluetooth
import Foundation

/// Experimental receive-only history reader for an InPen already authorized on this iPhone.
/// No insulin-delivery commands exist in this class. Manufacturer pairing is not implemented.
@MainActor final class InPenBluetoothReader: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = InPenBluetoothReader()
    struct NearbyPen: Identifiable {
        let id: UUID
        let name: String
    }

    @Published private(set) var nearby: [NearbyPen] = []
    @Published private(set) var status = "Not connected"
    @Published private(set) var lastSync: Date?
    @Published private(set) var enabled = false
    private var central: CBCentralManager?
    private var peripherals = [UUID: CBPeripheral]()
    private var pen: CBPeripheral?
    private var characteristics = [CBUUID: CBCharacteristic]()
    private var pendingServices = 0
    private var epoch: Date?
    private var clockRequestedAt: Date?
    private var lastIndex: UInt16 = 0
    private var requestedIndices = Set<UInt16>()
    private var receivedIndices = Set<UInt16>()
    private var syncTimer: Timer?
    private var timeout: Timer?
    private var blocked = false
    private let store = ExternalInsulinStore.shared

    private enum GATT {
        static let scan = CBUUID(string: "BFD0")
        static let auth = CBUUID(string: "c8a1bfe3-bc3f-493c-af8d-ae9824f583c6")
        static let clock = CBUUID(string: "c8a1bfd4-bc3f-493c-af8d-ae9824f583c6")
        static let index = CBUUID(string: "c8a1bfde-bc3f-493c-af8d-ae9824f583c6")
        static let start = CBUUID(string: "c8a1bfe1-bc3f-493c-af8d-ae9824f583c6")
        static let end = CBUUID(string: "c8a1bfe2-bc3f-493c-af8d-ae9824f583c6")
        static let request = CBUUID(string: "c8a1bfda-bc3f-493c-af8d-ae9824f583c6")
        static let records = CBUUID(string: "c8a1bfd1-bc3f-493c-af8d-ae9824f583c6")
        static let keepAlive = CBUUID(string: "c8a1bfdf-bc3f-493c-af8d-ae9824f583c6")
    }

    func resumeIfEnabled() {
        if UserDefaults.standard.bool(forKey: "externalInsulin.inPenEnabled") { start() }
    }

    func start() {
        enabled = true
        blocked = false
        UserDefaults.standard.set(true, forKey: "externalInsulin.inPenEnabled")
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "org.iaps.external-insulin.inpen"
            ])
        } else if central?.state == .poweredOn { scanOrReconnect() }
    }

    func stop() {
        enabled = false
        UserDefaults.standard.set(false, forKey: "externalInsulin.inPenEnabled")
        central?.stopScan()
        syncTimer?.invalidate()
        timeout?.invalidate()
        if let pen = pen { central?.cancelPeripheralConnection(pen) }
        status = "Stopped"
    }

    func connect(_ id: UUID) {
        guard let selected = peripherals[id] else { return }
        central?.stopScan()
        UserDefaults.standard.set(id.uuidString, forKey: "externalInsulin.inPenID")
        pen = selected
        status = "Connecting to \(selected.name ?? "InPen")"
        central?.connect(selected)
        armTimeout()
    }

    func sync() {
        guard enabled, !blocked, pen?.state == .connected, timeout == nil else { return }
        requestedIndices = []
        receivedIndices = []
        epoch = nil
        status = "Checking InPen authorization"
        armTimeout()
        read(GATT.auth)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard enabled else { return }
        switch central.state {
        case .poweredOn: scanOrReconnect()
        case .unauthorized: status = "Bluetooth permission is required in iPhone Settings."
        case .poweredOff: status = "Bluetooth is off."
        default: status = "Bluetooth is unavailable."
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard enabled, let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let id = UserDefaults.standard.string(forKey: "externalInsulin.inPenID"),
              let selected = restored.first(where: { $0.identifier.uuidString == id }) else { return }
        pen = selected
        peripherals[selected.identifier] = selected
        selected.delegate = self
        if selected.state == .connected { selected.discoverServices(nil) }
    }

    private func scanOrReconnect() {
        guard enabled, !blocked else { return }
        if let id = UserDefaults.standard.string(forKey: "externalInsulin.inPenID"),
           let uuid = UUID(uuidString: id),
           let previous = central?.retrievePeripherals(withIdentifiers: [uuid]).first {
            peripherals[uuid] = previous
            connect(uuid)
        } else {
            nearby = []
            status = "Scanning for InPen"
            central?.scanForPeripherals(withServices: [GATT.scan])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        if !nearby.contains(where: { $0.id == peripheral.identifier }) {
            nearby.append(NearbyPen(id: peripheral.identifier, name: peripheral.name ?? "InPen"))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pen = peripheral
        peripheral.delegate = self
        characteristics = [:]
        status = "Reading InPen services"
        armTimeout()
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(error?.localizedDescription ?? "InPen connection failed.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        syncTimer?.invalidate()
        timeout?.invalidate()
        timeout = nil
        if enabled, !blocked {
            status = "Disconnected; waiting to reconnect"
            central.connect(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            fail(error?.localizedDescription ?? "InPen services were not found."); return
        }
        pendingServices = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { fail(error!.localizedDescription); return }
        for characteristic in service.characteristics ?? [] { characteristics[characteristic.uuid] = characteristic }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        let required = [GATT.auth, GATT.clock, GATT.index, GATT.start, GATT.end, GATT.request, GATT.records, GATT.keepAlive]
        guard required.allSatisfy({ characteristics[$0] != nil }) else {
            fail("This pen does not expose the supported InPen history service."); return
        }
        timeout?.invalidate()
        timeout = nil
        sync()
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else {
            fail(error?.localizedDescription ?? "InPen returned no data."); return
        }
        do {
            switch characteristic.uuid {
            case GATT.auth:
                guard Array(value).first == 0 else {
                    fail("InPen requires manufacturer pairing. Direct iAPS pairing is not implemented yet. Keep your current InPen setup.")
                    return
                }
                clockRequestedAt = Date()
                read(GATT.clock)
            case GATT.clock:
                guard let requestedAt = clockRequestedAt, Date().timeIntervalSince(requestedAt) <= 5 else {
                    throw ExternalInsulinError.invalidClock
                }
                epoch = try InPenRecordDecoder.epoch(penTime: value, sampledAt: requestedAt)
                read(GATT.index)
            case GATT.index:
                let b = Array(value)
                guard b.count == 2 else { throw ExternalInsulinError.invalidPacket }
                lastIndex = UInt16(b[0]) | UInt16(b[1]) << 8
                guard lastIndex > 0 else { completeSync(); return }
                // Bounded backfill; repeated packets are idempotent. No cursor advances past missing packets.
                let first = lastIndex > 79 ? lastIndex - 79 : 1
                requestedIndices = Set(first ... lastIndex)
                guard let notify = characteristics[GATT.records],
                      notify.properties.contains(.indicate) || notify.properties.contains(.notify) else {
                    throw ExternalInsulinError.invalidPacket
                }
                if notify.isNotifying { write(Data([0xF1]), to: GATT.keepAlive) }
                else { peripheral.setNotifyValue(true, for: notify) }
            case GATT.records:
                guard let epoch = epoch else { throw ExternalInsulinError.invalidClock }
                let record = try InPenRecordDecoder.decode(value, epoch: epoch, deviceID: peripheral.identifier.uuidString)
                let b = Array(value)
                let index = UInt16(b[0]) << 8 | UInt16(b[1])
                guard requestedIndices.contains(index) else { throw ExternalInsulinError.invalidPacket }
                try store.add(record)
                receivedIndices.insert(index)
                if receivedIndices == requestedIndices { completeSync() }
            default: break
            }
        } catch { fail(error.localizedDescription) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else {
            fail(error?.localizedDescription ?? "InPen history notifications could not start."); return
        }
        write(Data([0xF1]), to: GATT.keepAlive)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { fail(error!.localizedDescription); return }
        switch characteristic.uuid {
        case GATT.keepAlive: write(littleEndian(requestedIndices.min() ?? 1), to: GATT.start)
        case GATT.start: write(littleEndian(lastIndex), to: GATT.end)
        case GATT.end: write(Data([0xC7]), to: GATT.request)
        case GATT.request: status = "Receiving InPen records for review"
        default: break
        }
    }

    private func read(_ uuid: CBUUID) {
        guard let c = characteristics[uuid], c.properties.contains(.read) else {
            fail("An InPen history characteristic cannot be read."); return
        }
        pen?.readValue(for: c)
    }

    private func write(_ data: Data, to uuid: CBUUID) {
        guard let c = characteristics[uuid], c.properties.contains(.write) else {
            fail("An InPen history request could not be sent."); return
        }
        pen?.writeValue(data, for: c, type: .withResponse)
    }

    private func littleEndian(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private func armTimeout() {
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fail("InPen sync timed out. History may be incomplete; received records are preserved.") }
        }
    }

    private func completeSync() {
        timeout?.invalidate()
        timeout = nil
        lastSync = Date()
        status = "History received. Review each dispense as injection or prime."
    }

    private func fail(_ message: String) {
        blocked = true
        status = message
        syncTimer?.invalidate()
        timeout?.invalidate()
        timeout = nil
        if let pen = pen { central?.cancelPeripheralConnection(pen) }
    }
}
