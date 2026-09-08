import 'package:shared_preferences/shared_preferences.dart';

import '../models/tcloud_file.dart';
import '../models/tcloud_folder.dart';
import '../telegram/tdlib_service.dart';

class LibraryPreferencesService {
  LibraryPreferencesService._();

  static final instance = LibraryPreferencesService._();

  static const _favoritesKey = 'tcloud_library_favorites_v1';
  static const _trashKey = 'tcloud_library_trash_v1';
  static const _hiddenAlbumsKey = 'tcloud_gallery_hidden_albums_v1';
  static const _backupPausedKey = 'tcloud_gallery_backup_paused_v1';
  static const _mobileDataKey = 'tcloud_gallery_mobile_data_v1';
  static const _secureScreenKey = 'tcloud_secure_screen_v1';

  Future<Set<String>> favorites() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_favoritesKey) ?? const <String>[]).toSet();
  }

  Future<bool> isFavorite(TCloudFile file) async =>
      (await favorites()).contains(file.contentIdentity);

  Future<bool> toggleFavorite(TCloudFile file) async {
    final prefs = await SharedPreferences.getInstance();
    final values = (prefs.getStringList(_favoritesKey) ?? const <String>[])
        .toSet();
    final added = values.add(file.contentIdentity);
    if (!added) values.remove(file.contentIdentity);
    await prefs.setStringList(_favoritesKey, values.toList()..sort());
    return added;
  }

  Future<Set<String>> trash() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_trashKey) ?? const <String>[]).toSet();
  }

  Future<void> moveToTrash(Iterable<TCloudFile> files) async {
    final prefs = await SharedPreferences.getInstance();
    final values = (prefs.getStringList(_trashKey) ?? const <String>[]).toSet();
    values.addAll(files.map((file) => file.contentIdentity));
    await prefs.setStringList(_trashKey, values.toList()..sort());
  }

  Future<void> restoreFromTrash(Iterable<TCloudFile> files) async {
    final prefs = await SharedPreferences.getInstance();
    final values = (prefs.getStringList(_trashKey) ?? const <String>[]).toSet();
    values.removeAll(files.map((file) => file.contentIdentity));
    await prefs.setStringList(_trashKey, values.toList()..sort());
  }

  Future<void> emptyTrash() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_trashKey);
  }

  Future<Set<String>> hiddenAlbums() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_hiddenAlbumsKey) ?? const <String>[]).toSet();
  }

  Future<bool> isAlbumHidden(TCloudFolder folder) async =>
      (await hiddenAlbums()).contains(folder.title.trim().toLowerCase());

  Future<void> setAlbumHidden(TCloudFolder folder, bool hidden) async {
    final prefs = await SharedPreferences.getInstance();
    final values = (prefs.getStringList(_hiddenAlbumsKey) ?? const <String>[])
        .toSet();
    final key = folder.title.trim().toLowerCase();
    if (hidden) {
      values.add(key);
    } else {
      values.remove(key);
    }
    await prefs.setStringList(_hiddenAlbumsKey, values.toList()..sort());
    final nativeNames = values.map((value) {
      const prefix = 'galeria / ';
      return value.startsWith(prefix) ? value.substring(prefix.length) : value;
    });
    await TdlibService.instance.setBackgroundHiddenAlbums(nativeNames);
  }

  Future<bool> backupPaused() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_backupPausedKey) ?? false;
  }

  Future<void> setBackupPaused(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_backupPausedKey, value);
  }

  Future<bool> allowMobileData() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_mobileDataKey) ?? false;
  }

  Future<void> setAllowMobileData(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mobileDataKey, value);
  }

  Future<bool> secureScreen() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_secureScreenKey) ?? false;
  }

  Future<void> setSecureScreen(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_secureScreenKey, value);
    await TdlibService.instance.setSecureScreen(value);
  }
}
