import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';

const int wsPort = 8765;
const int discoveryPort = 8766;

// ================= Charte graphique Syncrus =================
class SC {
  static const night = Color(0xFF0E1A26); // fond
  static const deep = Color(0xFF152536); // surfaces
  static const slate = Color(0xFF1E3448); // surfaces élevées
  static const teal = Color(0xFF3E7C8B); // secondaire
  static const aqua = Color(0xFF2FA4A6); // accent froid
  static const mint = Color(0xFF5FD3A6); // accent principal
  static const text = Color(0xFFE6F1F0);
  static const muted = Color(0xFF8AA3AE);
  static const danger = Color(0xFFFF7A7A);
  static const warn = Color(0xFFF2C46D);

  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [mint, aqua],
  );
  static const bgGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF1B3445), night],
    stops: [0, .45],
  );
}

void main() {
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: SC.night,
  ));
  runApp(const SyncrusApp());
}

class SyncrusApp extends StatelessWidget {
  const SyncrusApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = const ColorScheme.dark(
      primary: SC.mint,
      onPrimary: SC.night,
      secondary: SC.aqua,
      surface: SC.deep,
      onSurface: SC.text,
      error: SC.danger,
    );
    return MaterialApp(
      title: 'Syncrus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: SC.night,
        snackBarTheme: SnackBarThemeData(
          backgroundColor: SC.slate,
          contentTextStyle: const TextStyle(color: SC.text),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: SC.slate,
          labelStyle: const TextStyle(color: SC.muted),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: SC.mint, width: 1.5),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: SC.deep,
          dragHandleColor: SC.teal,
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: SC.slate,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ================= Modèle =================
class Clip {
  final String id;
  final String kind; // 'text', 'image' ou 'file'
  final String text;
  final String name;
  final int size;
  final Uint8List? bytes;
  final String mime;
  final int w, h;
  final String? hash;
  final double ts;
  final String source;
  Clip({
    required this.id,
    required this.kind,
    this.text = '',
    this.name = '',
    this.size = 0,
    this.bytes,
    this.mime = 'image/png',
    this.w = 0,
    this.h = 0,
    this.hash,
    required this.ts,
    required this.source,
  });

  bool get isImage => kind == 'image';
  bool get isFile => kind == 'file';

  factory Clip.fromJson(Map<String, dynamic> j) => Clip(
        id: j['id'],
        kind: j['kind'] ?? 'text',
        text: j['text'] ?? '',
        name: j['name'] ?? '',
        size: j['size'] ?? 0,
        bytes: j['data'] != null ? base64Decode(j['data']) : null,
        mime: j['mime'] ?? 'image/png',
        w: j['w'] ?? 0,
        h: j['h'] ?? 0,
        hash: j['hash'],
        ts: (j['ts'] as num).toDouble(),
        source: j['source'] ?? 'pc',
      );

  DateTime get date => DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
}

enum LinkState { disconnected, connecting, connected }

// ================= Page principale =================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;
  LinkState _state = LinkState.disconnected;
  String _host = '';
  String _pin = '';
  String _pcName = '';
  String _search = '';
  bool _autoCopy = true;
  bool _manualClose = false;
  Timer? _retry;
  final List<Clip> _clips = [];
  final Map<String, _Dl> _downloads = {}; // fichiers PC -> téléphone
  String _fp = ''; // empreinte du PC appairé (sécurité)
  String? _seenFp; // empreinte présentée lors de la connexion en cours
  bool _fpMismatch = false;
  String? _upName; // fichier en cours d'envoi vers le PC
  double _upProgress = 0;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final docs = await getApplicationDocumentsDirectory();
    _filesDir = Directory('${docs.path}/Syncrus')..createSync(recursive: true);
    final p = await SharedPreferences.getInstance();
    setState(() {
      _host = p.getString('host') ?? '';
      _pin = p.getString('pin') ?? '';
      _autoCopy = p.getBool('autoCopy') ?? true;
      _fp = p.getString('fingerprint') ?? '';
    });
    if (_host.isNotEmpty && _pin.isNotEmpty) _connect();
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('host', _host);
    await p.setString('pin', _pin);
    await p.setBool('autoCopy', _autoCopy);
    await p.setString('fingerprint', _fp);
  }

  static String _fingerprintOf(List<int> der) {
    final hex = sha256.convert(der).toString().toUpperCase().substring(0, 16);
    return [for (var i = 0; i < 16; i += 4) hex.substring(i, i + 4)].join('-');
  }

  /// Connexion chiffrée (TLS). Le certificat du PC est vérifié par son empreinte :
  /// mémorisée à la 1re connexion, puis exigée à chaque fois.
  HttpClient _tlsClient() {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
      final fp = _fingerprintOf(cert.der);
      _seenFp = fp;
      if (_fp.isEmpty) return true; // premier appairage
      if (fp == _fp) return true;
      _fpMismatch = true;
      return false;
    };
    return client;
  }

  Future<void> _forgetPc() async {
    _fp = '';
    _fpMismatch = false;
    await _savePrefs();
    _toast('PC oublié : la prochaine connexion refera l\'appairage');
  }

  // ---------- Connexion ----------
  Future<void> _connect() async {
    _retry?.cancel();
    _manualClose = false;
    await _disconnect(silent: true);
    setState(() => _state = LinkState.connecting);
    _fpMismatch = false;
    try {
      final socket = await WebSocket.connect('wss://$_host:$wsPort', customClient: _tlsClient())
          .timeout(const Duration(seconds: 6));
      socket.pingInterval = const Duration(seconds: 25);
      _channel = IOWebSocketChannel(socket);
      _channel!.sink.add(jsonEncode({'type': 'auth', 'pin': _pin}));
      _sub = _channel!.stream.listen(
        _onMessage,
        onDone: _onClosed,
        onError: (_) => _onClosed(),
      );
    } catch (_) {
      if (_fpMismatch) {
        _manualClose = true; // on n'insiste pas avec une machine inconnue
        if (mounted) {
          setState(() => _state = LinkState.disconnected);
          _toast('PC non reconnu : connexion refusée');
        }
        return;
      }
      _onClosed();
    }
  }

  Future<void> _disconnect({bool silent = false}) async {
    await _sub?.cancel();
    await _channel?.sink.close();
    _sub = null;
    _channel = null;
    if (!silent && mounted) setState(() => _state = LinkState.disconnected);
  }

  void _onClosed() {
    if (!mounted) return;
    final wasConnected = _state == LinkState.connected;
    final willRetry = !_manualClose && _host.isNotEmpty;
    // Coupure brève : on affiche "Reconnexion…" plutôt que rouge, et on garde l'historique.
    setState(() => _state = wasConnected && willRetry ? LinkState.connecting : LinkState.disconnected);
    if (willRetry) {
      _retry = Timer(Duration(seconds: wasConnected ? 1 : 3), _connect);
    }
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'auth_error':
        _manualClose = true;
        _toast(msg['reason'] == 'blocked' ? 'Trop d\'essais : réessaie dans 1 minute' : 'PIN incorrect');
        _disconnect();
        break;
      case 'hello':
        if (_fp.isEmpty && _seenFp != null) {
          _fp = _seenFp!;
          _savePrefs();
          _toast('PC appairé 🔒 empreinte $_fp');
        }
        setState(() {
          _state = LinkState.connected;
          _pcName = msg['name'] ?? 'PC';
          _clips
            ..clear()
            ..addAll((msg['history'] as List).map((e) => Clip.fromJson(e)).toList().reversed);
        });
        break;
      case 'clip':
        final c = Clip.fromJson(msg['item']);
        setState(() {
          _clips.removeWhere((e) => c.isImage
              ? e.hash == c.hash
              : c.isFile
                  ? e.id == c.id
                  : (e.kind == 'text' && e.text == c.text));
          _clips.insert(0, c);
        });
        if (c.isFile) {
          if (c.source == 'pc') {
            HapticFeedback.mediumImpact();
            _toast('Fichier disponible : ${c.name}');
          }
        } else if (c.isImage) {
          if (c.source == 'pc') {
            HapticFeedback.mediumImpact();
            _toast('Image reçue du PC');
          }
        } else if (_autoCopy && c.source == 'pc') {
          Clipboard.setData(ClipboardData(text: c.text));
        }
        break;
      case 'deleted':
        setState(() => _clips.removeWhere((e) => e.id == msg['id']));
        break;
      case 'cleared':
        setState(() => _clips.clear());
        break;
      case 'file_begin':
        _fileBegin(msg);
        break;
      case 'file_chunk':
        final d = _downloads[msg['id']];
        if (d != null && !d.done) {
          final data = base64Decode(msg['data']);
          d.sink.add(data);
          setState(() => d.got += data.length);
        }
        break;
      case 'file_end':
        _fileEnd(msg['id']);
        break;
      case 'file_error':
        setState(() => _downloads.remove(msg['id']));
        _toast(msg['error'] ?? 'Erreur de téléchargement');
        break;
    }
  }

  void _send(Map<String, dynamic> m) => _channel?.sink.add(jsonEncode(m));

  // ---------- Découverte auto (UDP broadcast) ----------
  Future<List<_Found>> _discover() async {
    final found = <String, _Found>{};
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;
    sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = sock.receive();
      if (d == null) return;
      try {
        final j = jsonDecode(utf8.decode(d.data));
        if (j['app'] == 'syncrus') {
          found[d.address.address] = _Found(d.address.address, j['name'] ?? 'PC');
        }
      } catch (_) {}
    });
    final payload = utf8.encode('SYNCRUS_DISCOVER');
    final targets = <String>{'255.255.255.255', '192.168.137.255', '192.168.43.255'};
    for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in iface.addresses) {
        final p = a.address.split('.');
        targets.add('${p[0]}.${p[1]}.${p[2]}.255');
      }
    }
    for (var i = 0; i < 3; i++) {
      for (final t in targets) {
        try {
          sock.send(payload, InternetAddress(t), discoveryPort);
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    sock.close();
    return found.values.toList();
  }

  // ---------- Actions ----------
  void _toast(String s) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(milliseconds: 1200)));

  Future<void> _sendPhoneClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      _toast('Presse-papier vide');
      return;
    }
    _send({'type': 'push', 'text': text});
    _toast('Envoyé au PC');
  }

  bool _sendingPhotos = false;

  // ---------- Fichiers ----------
  Directory? _filesDir;

  void _fileBegin(Map<String, dynamic> msg) {
    final folder = _filesDir;
    if (folder == null) return;
    final name = (msg['name'] as String).split(RegExp(r'[\\/]')).last;
    final file = File('${folder.path}/$name');
    setState(() => _downloads[msg['id']] = _Dl(file, file.openWrite(), msg['size'] ?? 0));
  }

  Future<void> _fileEnd(String id) async {
    final d = _downloads[id];
    if (d == null) return;
    await d.sink.close();
    setState(() => d.done = true);
    HapticFeedback.mediumImpact();
    _toast('Téléchargé : ${d.file.uri.pathSegments.last}');
  }

  void _download(Clip c) {
    if (_downloads.containsKey(c.id)) return;
    setState(() => _downloads[c.id] = _Dl.pending());
    _send({'type': 'get_file', 'id': c.id});
  }

  Future<void> _shareFile(Clip c) async {
    final d = _downloads[c.id];
    if (d == null || !d.done) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(d.file.path)]));
  }

  Future<void> _sendFiles() async {
    if (_upName != null) return;
    final res = await FilePicker.platform.pickFiles(allowMultiple: true, withReadStream: true);
    if (res == null || res.files.isEmpty) return;
    try {
      for (final f in res.files) {
        final stream = f.readStream;
        if (stream == null) continue;
        final id = '${DateTime.now().microsecondsSinceEpoch}';
        setState(() {
          _upName = f.name;
          _upProgress = 0;
        });
        _send({'type': 'upload_begin', 'id': id, 'name': f.name, 'size': f.size});
        final buf = BytesBuilder(copy: false);
        var sent = 0;
        Future<void> flush() async {
          if (buf.isEmpty) return;
          final bytes = buf.takeBytes();
          _send({'type': 'upload_chunk', 'id': id, 'data': base64Encode(bytes)});
          sent += bytes.length;
          if (mounted) setState(() => _upProgress = f.size > 0 ? sent / f.size : 0);
          await Future.delayed(const Duration(milliseconds: 15)); // laisse respirer le réseau
        }

        await for (final part in stream) {
          buf.add(part);
          if (buf.length >= 256 * 1024) await flush();
        }
        await flush();
        _send({'type': 'upload_end', 'id': id});
      }
      HapticFeedback.mediumImpact();
      _toast(res.files.length == 1 ? 'Fichier envoyé au PC' : '${res.files.length} fichiers envoyés');
    } catch (_) {
      _toast('Échec de l\'envoi du fichier');
    } finally {
      if (mounted) setState(() => _upName = null);
    }
  }

  String _size(int n) {
    if (n < 1024) return '$n o';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} Ko';
    if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} Mo';
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} Go';
  }

  IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'doc' || 'docx' || 'odt' || 'txt' || 'rtf' => Icons.description_outlined,
      'xls' || 'xlsx' || 'csv' || 'ods' => Icons.table_chart_outlined,
      'ppt' || 'pptx' || 'odp' => Icons.slideshow_outlined,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
      'mp3' || 'wav' || 'm4a' || 'ogg' || 'flac' => Icons.audiotrack_outlined,
      'mp4' || 'mkv' || 'avi' || 'mov' || 'webm' => Icons.movie_outlined,
      'apk' => Icons.android,
      'py' || 'dart' || 'js' || 'php' || 'html' || 'css' || 'java' || 'kt' => Icons.code,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Widget _fileBody(Clip c) {
    final d = _downloads[c.id];
    final fromPc = c.source == 'pc';
    Widget action;
    if (!fromPc) {
      action = const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check_circle, size: 16, color: SC.aqua),
        SizedBox(width: 4),
        Text('Sur le PC', style: TextStyle(color: SC.aqua, fontSize: 12)),
      ]);
    } else if (d == null) {
      action = _SmallButton(icon: Icons.download_rounded, label: 'Télécharger', onTap: () => _download(c));
    } else if (!d.done) {
      final pct = d.size > 0 ? d.got / d.size : null;
      action = SizedBox(
        width: 38,
        height: 38,
        child: Stack(alignment: Alignment.center, children: [
          CircularProgressIndicator(value: pct, strokeWidth: 3, color: SC.mint, backgroundColor: SC.slate),
          if (pct != null) Text('${(pct * 100).round()}', style: const TextStyle(fontSize: 11, color: SC.text)),
        ]),
      );
    } else {
      action = _SmallButton(icon: Icons.open_in_new_rounded, label: 'Ouvrir', onTap: () => _shareFile(c));
    }
    return Row(children: [
      Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: SC.slate,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(_fileIcon(c.name), color: SC.mint),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: SC.text, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(_size(c.size), style: const TextStyle(color: SC.muted, fontSize: 12)),
        ]),
      ),
      const SizedBox(width: 8),
      action,
    ]);
  }

  Future<void> _sendPhotos() async {
    if (_sendingPhotos) return;
    final picks = await ImagePicker().pickMultiImage(maxWidth: 2560, maxHeight: 2560, imageQuality: 85);
    if (picks.isEmpty) return;
    setState(() => _sendingPhotos = true);
    try {
      for (var i = 0; i < picks.length; i++) {
        if (picks.length > 1) _toast('Envoi ${i + 1}/${picks.length}…');
        final bytes = await picks[i].readAsBytes();
        final mime = picks[i].path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
        _send({'type': 'push_image', 'data': base64Encode(bytes), 'mime': mime});
        await Future.delayed(const Duration(milliseconds: 150));
      }
      HapticFeedback.mediumImpact();
      _toast(picks.length == 1 ? 'Photo envoyée, colle-la sur le PC' : '${picks.length} photos envoyées');
    } catch (_) {
      _toast('Échec de l\'envoi');
    } finally {
      if (mounted) setState(() => _sendingPhotos = false);
    }
  }

  Future<void> _shareImage(Clip c) async {
    if (c.bytes == null) return;
    final ext = c.mime == 'image/jpeg' ? 'jpg' : 'png';
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/syncrus_${c.id}.$ext');
    await f.writeAsBytes(c.bytes!);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: c.mime)]));
  }

  void _openImage(Clip c) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: .92),
      pageBuilder: (_, __, ___) => _ImageViewer(clip: c, onShare: () => _shareImage(c)),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  String _ago(DateTime d) {
    final s = DateTime.now().difference(d).inSeconds;
    if (s < 60) return 'à l\'instant';
    if (s < 3600) return 'il y a ${s ~/ 60} min';
    if (s < 86400) return 'il y a ${s ~/ 3600} h';
    return '${d.day}/${d.month} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  }

  // ---------- Feuille de connexion ----------
  Future<void> _openConnectSheet() async {
    final hostCtrl = TextEditingController(text: _host);
    final pinCtrl = TextEditingController(text: _pin);
    List<_Found> results = [];
    bool scanning = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Image.asset('assets/logo.png', height: 28),
                const SizedBox(width: 10),
                const Text('Connexion au PC',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: SC.text)),
              ]),
              const SizedBox(height: 18),
              _GradientButton(
                icon: scanning ? null : Icons.radar,
                loading: scanning,
                label: scanning ? 'Recherche…' : 'Rechercher automatiquement',
                onTap: scanning
                    ? null
                    : () async {
                        setSheet(() => scanning = true);
                        results = await _discover();
                        setSheet(() => scanning = false);
                        if (results.isEmpty) _toast('Aucun PC trouvé, saisis l\'adresse');
                      },
              ),
              ...results.map((r) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ListTile(
                      tileColor: SC.slate,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      leading: const Icon(Icons.computer, color: SC.mint),
                      title: Text(r.name, style: const TextStyle(color: SC.text)),
                      subtitle: Text(r.ip, style: const TextStyle(color: SC.muted)),
                      onTap: () => setSheet(() => hostCtrl.text = r.ip),
                    ),
                  )),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: _ModeChip(
                    icon: Icons.usb,
                    label: 'Câble USB',
                    selected: hostCtrl.text == '127.0.0.1',
                    onTap: () => setSheet(() => hostCtrl.text = '127.0.0.1'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ModeChip(
                    icon: Icons.wifi_tethering,
                    label: 'Point d\'accès PC',
                    selected: hostCtrl.text == '192.168.137.1',
                    onTap: () => setSheet(() => hostCtrl.text = '192.168.137.1'),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              TextField(
                controller: hostCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                style: const TextStyle(color: SC.text),
                onChanged: (_) => setSheet(() {}),
                decoration: const InputDecoration(
                  labelText: 'Adresse IP du PC',
                  prefixIcon: Icon(Icons.lan_outlined, color: SC.muted),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pinCtrl,
                keyboardType: TextInputType.number,
                maxLength: 4,
                obscureText: true,
                style: const TextStyle(color: SC.text, letterSpacing: 8),
                decoration: const InputDecoration(
                  labelText: 'PIN',
                  counterText: '',
                  prefixIcon: Icon(Icons.lock_outline, color: SC.muted),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (_fpMismatch ? SC.danger : SC.mint).withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: (_fpMismatch ? SC.danger : SC.teal).withValues(alpha: .5)),
                ),
                child: Row(children: [
                  Icon(_fpMismatch ? Icons.gpp_bad_outlined : Icons.lock_outline,
                      color: _fpMismatch ? SC.danger : SC.mint, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _fpMismatch
                          ? 'Ce PC présente l\'empreinte ${_seenFp ?? '?'}, différente de celle appairée ($_fp). '
                              'Compare avec le menu de l\'icône Syncrus du PC.'
                          : _fp.isEmpty
                              ? 'Connexion chiffrée. L\'empreinte du PC sera mémorisée à la 1re connexion.'
                              : 'Connexion chiffrée · PC appairé\n$_fp',
                      style: const TextStyle(color: SC.text, fontSize: 12.5, height: 1.35),
                    ),
                  ),
                  if (_fp.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        await _forgetPc();
                        setSheet(() {});
                        setState(() {});
                      },
                      child: const Text('Oublier', style: TextStyle(color: SC.muted)),
                    ),
                ]),
              ),
              const SizedBox(height: 18),
              _GradientButton(
                label: 'Se connecter',
                icon: Icons.link,
                onTap: () {
                  _host = hostCtrl.text.trim();
                  _pin = pinCtrl.text.trim();
                  _savePrefs();
                  Navigator.pop(ctx);
                  _connect();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final visible = _search.isEmpty
        ? _clips
        : _clips
            .where((c) => (c.isFile ? c.name : c.text).toLowerCase().contains(_search.toLowerCase()) && !c.isImage)
            .toList();

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: SC.bgGradient),
        child: SafeArea(
          bottom: false,
          child: Column(children: [
            _header(),
            _statusCard(),
            if (_upName != null) _uploadBanner(),
            _searchBar(),
            Expanded(child: visible.isEmpty ? _emptyState() : _list(visible)),
          ]),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _state == LinkState.connected
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              _RoundAction(
                icon: Icons.add_photo_alternate_outlined,
                loading: _sendingPhotos,
                tooltip: 'Envoyer des photos au PC',
                onTap: _sendPhotos,
              ),
              const SizedBox(width: 10),
              _RoundAction(
                icon: Icons.attach_file_rounded,
                loading: _upName != null,
                tooltip: 'Envoyer des fichiers au PC',
                onTap: _sendFiles,
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 180,
                child: _GradientButton(
                  label: 'Envoyer au PC',
                  icon: Icons.north_east_rounded,
                  onTap: _sendPhoneClipboard,
                  shadow: true,
                ),
              ),
            ])
          : null,
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
        child: Row(children: [
          Image.asset('assets/logo.png', height: 34),
          const SizedBox(width: 10),
          ShaderMask(
            shaderCallback: (r) => SC.brandGradient.createShader(r),
            child: const Text('Syncrus',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: .3)),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Copie auto',
            icon: Icon(_autoCopy ? Icons.bolt_rounded : Icons.bolt_outlined,
                color: _autoCopy ? SC.mint : SC.muted),
            onPressed: () {
              setState(() => _autoCopy = !_autoCopy);
              _savePrefs();
              _toast(_autoCopy ? 'Copie auto activée' : 'Copie auto désactivée');
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: SC.muted),
            onSelected: (v) {
              if (v == 'clear') _send({'type': 'clear'});
              if (v == 'conn') _openConnectSheet();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'conn', child: Text('Connexion')),
              PopupMenuItem(value: 'clear', child: Text('Vider l\'historique')),
            ],
          ),
        ]),
      );

  Widget _uploadBanner() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: SC.deep, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.upload_rounded, size: 18, color: SC.mint),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Envoi de $_upName',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: SC.text)),
              ),
              Text('${(_upProgress * 100).round()} %', style: const TextStyle(color: SC.muted, fontSize: 12)),
            ]),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                  value: _upProgress, minHeight: 6, color: SC.mint, backgroundColor: SC.slate),
            ),
          ]),
        ),
      );

  Widget _statusCard() {
    final (Color dot, String title, String sub) = _fpMismatch
        ? (SC.danger, 'PC non reconnu', 'Empreinte différente, touche pour vérifier')
        : switch (_state) {
      LinkState.connected => (SC.mint, 'Connecté 🔒', _pcName),
      LinkState.connecting => (SC.warn, 'Connexion…', _host),
      LinkState.disconnected =>
        (SC.danger, _host.isEmpty ? 'Non configuré' : 'Déconnecté', _host.isEmpty ? 'Touche pour connecter ton PC' : _host),
    };
    final mode = _host == '127.0.0.1'
        ? Icons.usb
        : _host == '192.168.137.1'
            ? Icons.wifi_tethering
            : Icons.wifi;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _openConnectSheet,
          child: Ink(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: SC.deep.withValues(alpha: .85),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: dot.withValues(alpha: .35)),
            ),
            child: Row(children: [
              _PulseDot(color: dot, pulsing: _state != LinkState.disconnected),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(color: SC.text, fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(sub, style: const TextStyle(color: SC.muted, fontSize: 13)),
                ]),
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: SC.slate, borderRadius: BorderRadius.circular(12)),
                child: Icon(mode, color: SC.aqua, size: 20),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: TextField(
          onChanged: (v) => setState(() => _search = v),
          style: const TextStyle(color: SC.text),
          decoration: InputDecoration(
            hintText: 'Rechercher dans l\'historique',
            hintStyle: const TextStyle(color: SC.muted),
            prefixIcon: const Icon(Icons.search, color: SC.muted),
            fillColor: SC.deep,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
          ),
        ),
      );

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Opacity(opacity: .35, child: Image.asset('assets/logo.png', height: 120)),
            const SizedBox(height: 20),
            Text(
              _state == LinkState.connected ? 'Rien pour l\'instant' : 'Pas encore connecté',
              style: const TextStyle(color: SC.text, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              _state == LinkState.connected
                  ? 'Copie un texte ou une image sur ton PC, il apparaîtra ici.'
                  : 'Touche la carte de statut pour relier ton PC.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: SC.muted),
            ),
          ]),
        ),
      );

  Widget _list(List<Clip> visible) => ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
        itemCount: visible.length,
        itemBuilder: (_, i) {
          final c = visible[i];
          final fromPc = c.source == 'pc';
          return Dismissible(
            key: ValueKey(c.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 24),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: SC.danger.withValues(alpha: .15),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.delete_outline, color: SC.danger),
            ),
            onDismissed: (_) {
              setState(() => _clips.remove(c));
              _send({'type': 'delete', 'id': c.id});
            },
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () {
                    if (c.isImage) {
                      _openImage(c);
                      return;
                    }
                    if (c.isFile) {
                      final d = _downloads[c.id];
                      if (c.source == 'pc' && d == null) _download(c);
                      if (d != null && d.done) _shareFile(c);
                      return;
                    }
                    Clipboard.setData(ClipboardData(text: c.text));
                    HapticFeedback.lightImpact();
                    _toast('Copié');
                  },
                  child: Ink(
                    decoration: BoxDecoration(
                      color: SC.deep,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: SC.slate),
                    ),
                    child: IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Container(
                          width: 4,
                          decoration: BoxDecoration(
                            gradient: fromPc ? SC.brandGradient : null,
                            color: fromPc ? null : SC.teal,
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(18)),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              if (c.isImage && c.bytes != null)
                                Hero(
                                  tag: c.id,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      color: SC.night,
                                      height: 190,
                                      width: double.infinity,
                                      child: Image.memory(c.bytes!,
                                          fit: BoxFit.contain, cacheWidth: 900, gaplessPlayback: true),
                                    ),
                                  ),
                                )
                              else if (c.isFile)
                                _fileBody(c)
                              else
                                Text(c.text,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: SC.text, height: 1.35)),
                              const SizedBox(height: 10),
                              Row(children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: (fromPc ? SC.mint : SC.teal).withValues(alpha: .14),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(fromPc ? Icons.computer : Icons.smartphone,
                                        size: 12, color: fromPc ? SC.mint : SC.aqua),
                                    const SizedBox(width: 4),
                                    Text(fromPc ? 'PC' : 'Téléphone',
                                        style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: fromPc ? SC.mint : SC.aqua)),
                                  ]),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                    c.isImage ? '${_ago(c.date)} · ${c.w}×${c.h}' : _ago(c.date),
                                    style: const TextStyle(fontSize: 12, color: SC.muted)),
                                const Spacer(),
                                if (c.isFile)
                                  const SizedBox.shrink()
                                else if (c.isImage)
                                  GestureDetector(
                                    onTap: () => _shareImage(c),
                                    child: const Icon(Icons.ios_share_rounded, size: 18, color: SC.mint),
                                  )
                                else
                                  const Icon(Icons.copy_rounded, size: 16, color: SC.muted),
                              ]),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );

  @override
  void dispose() {
    _retry?.cancel();
    _disconnect(silent: true);
    super.dispose();
  }
}

// ================= Composants =================
class _GradientButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool loading;
  final bool shadow;
  const _GradientButton({required this.label, this.icon, this.onTap, this.loading = false, this.shadow = false});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null && !loading ? .5 : 1,
      child: Container(
        decoration: BoxDecoration(
          gradient: SC.brandGradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: shadow
              ? [BoxShadow(color: SC.mint.withValues(alpha: .35), blurRadius: 20, offset: const Offset(0, 6))]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 18),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (loading)
                  const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: SC.night))
                else if (icon != null)
                  Icon(icon, color: SC.night, size: 20),
                const SizedBox(width: 10),
                Text(label, style: const TextStyle(color: SC.night, fontWeight: FontWeight.w700, fontSize: 15)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Dl {
  final File file;
  final IOSink sink;
  final int size;
  int got = 0;
  bool done = false;
  bool get pending => size < 0;
  _Dl(this.file, this.sink, this.size);
  factory _Dl.pending() => _Dl(File(''), IOSink(StreamController<List<int>>().sink), -1);
}

class _SmallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SmallButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SC.mint.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: SC.mint),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: SC.mint, fontWeight: FontWeight.w600, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool loading;
  final String tooltip;
  const _RoundAction({required this.icon, required this.onTap, required this.tooltip, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: SC.slate,
        shape: const CircleBorder(side: BorderSide(color: SC.teal)),
        elevation: 6,
        shadowColor: Colors.black54,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: loading ? null : onTap,
          child: SizedBox(
            width: 54,
            height: 54,
            child: Center(
              child: loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: SC.mint))
                  : Icon(icon, color: SC.mint),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ModeChip({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: selected ? SC.mint.withValues(alpha: .12) : SC.slate,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? SC.mint : Colors.transparent),
          ),
          child: Column(children: [
            Icon(icon, color: selected ? SC.mint : SC.aqua),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(color: selected ? SC.mint : SC.text, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  final bool pulsing;
  const _PulseDot({required this.color, required this.pulsing});
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Stack(alignment: Alignment.center, children: [
          if (widget.pulsing)
            Container(
              width: 10 + 12 * _c.value,
              height: 10 + 12 * _c.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: .35 * (1 - _c.value)),
              ),
            ),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
          ),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }
}

class _ImageViewer extends StatelessWidget {
  final Clip clip;
  final VoidCallback onShare;
  const _ImageViewer({required this.clip, required this.onShare});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(
                  child: Hero(tag: clip.id, child: Image.memory(clip.bytes!, fit: BoxFit.contain)),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: SC.text),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: SizedBox(
                width: 220,
                child: _GradientButton(label: 'Partager / enregistrer', icon: Icons.ios_share_rounded, onTap: onShare),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Found {
  final String ip;
  final String name;
  _Found(this.ip, this.name);
}
