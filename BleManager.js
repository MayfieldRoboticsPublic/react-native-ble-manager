'use strict';
const React = require('react-native');
const bleManager = React.NativeModules.BleManager;
const BleEventEmitter = new React.NativeEventEmitter(bleManager);

const Events = {
  DidUpdateValueForCharacteristic: "BleManagerDidUpdateValueForCharacteristic",
  DidStopScan: "BleManagerDidStopScan",
  DidDiscoverPeripheral: "BleManagerDidDiscoverPeripheral",
  DidUpdateState: "BleManagerDidUpdateState",
  DidDisconnectPeripheral: "BleManagerDidDisconnectPeripheral",
};

class BleManager {
  checkState() {
    bleManager.checkState();
  }

  scan(serviceUUIDs, seconds, allowDuplicates = false) {
    return bleManager.scan(serviceUUIDs, seconds, allowDuplicates);
  }

  connect(peripheralId) {
    return bleManager.connect(peripheralId);
  }

  disconnect(peripheralId) {
    return bleManager.disconnect(peripheralId);
  }

  read(peripheralId, serviceUUID, characteristicUUID) {
    return bleManager.read(peripheralId, serviceUUID, characteristicUUID);
  }

  write(peripheralId, serviceUUID, characteristicUUID, data) {
    return bleManager.write(peripheralId, serviceUUID, characteristicUUID, data);
  }

  startNotification(peripheralId, serviceUUID, characteristicUUID) {
    return bleManager.startNotification(peripheralId, serviceUUID, characteristicUUID);
  }

  stopNotification(peripheralId, serviceUUID, characteristicUUID) {
    return bleManager.stopNotification(peripheralId, serviceUUID, characteristicUUID);
  }

  retrieveConnectedPeripheralsWithServices(serviceUUIDs) {
    return bleManager.retrieveConnectedPeripheralsWithServices(serviceUUIDs);
  }

  // Event Registration
  addUpdateValueForCharacteristicListener(listener) {
    return BleEventEmitter.addListener(Events.DidUpdateValueForCharacteristic, listener);
  }

  addStopScanListener(listener) {
    return BleEventEmitter.addListener(Events.DidStopScan, listener);
  }

  addDiscoverPeripheralListener(listener) {
    return BleEventEmitter.addListener(Events.DidDiscoverPeripheral, listener);
  }

  addUpdateStateListener(listener) {
    return BleEventEmitter.addListener(Events.DidUpdateState, listener);
  }

  addDisconnectPeripheralListener(listener) {
    return BleEventEmitter.addListener(Events.DidDisconnectPeripheral, listener);
  }
}

module.exports = new BleManager();
