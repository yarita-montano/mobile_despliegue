import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../theme/app_colors.dart';

/// Vista de ruta estilo delivery para el tecnico.
///
/// Muestra la ubicacion del cliente, la posicion en vivo del propio tecnico
/// (GPS del dispositivo) y la ruta optima por calles entre ambos, con ETA y
/// distancia. El constructor se mantiene intacto porque otras pantallas ya lo
/// usan (p. ej. historial_emergencias_screen y tecnico_dashboard_screen).
class TecnicoRutaScreen extends StatefulWidget {
  final int idIncidente;
  final double clienteLat;
  final double clienteLng;

  const TecnicoRutaScreen({
    super.key,
    required this.idIncidente,
    required this.clienteLat,
    required this.clienteLng,
  });

  @override
  State<TecnicoRutaScreen> createState() => _TecnicoRutaScreenState();
}

class _TecnicoRutaScreenState extends State<TecnicoRutaScreen> {
  final MapController _mapController = MapController();

  // Suscripcion al stream de posiciones del GPS del dispositivo.
  StreamSubscription<Position>? _posSub;

  // Estados de la pantalla.
  bool _cargandoPermiso = true;
  bool _permisoDenegado = false;
  String? _error;

  // Posicion viva del tecnico (desde el GPS, no desde el servidor).
  double? _tecnicoLat;
  double? _tecnicoLng;

  // Punto donde se solicito la ruta por ultima vez. Se usa para decidir si
  // conviene recalcular cuando el tecnico se mueve.
  LatLng? _ultimoPuntoRuta;

  // Ruta dibujada en el mapa (lista de puntos de la geometria OSRM).
  List<LatLng> _ruta = [];
  // Indica si la ruta actual es un fallback en linea recta (sin red/OSRM).
  bool _rutaEsFallback = false;
  bool _calculandoRuta = false;

  // Metricas mostradas en la barra de informacion.
  double? _distanciaKm;
  int? _etaMinutos;

  // Distancia minima (metros) que debe moverse el tecnico para recalcular la
  // ruta y evitar saturar el servidor OSRM publico.
  static const double _umbralRecalculoM = 120.0;

  @override
  void initState() {
    super.initState();
    _iniciarSeguimiento();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  LatLng get _cliente => LatLng(widget.clienteLat, widget.clienteLng);

  LatLng? get _tecnico => (_tecnicoLat != null && _tecnicoLng != null)
      ? LatLng(_tecnicoLat!, _tecnicoLng!)
      : null;

  /// Pide permisos de ubicacion y se suscribe al stream del GPS para mover el
  /// marcador del tecnico en vivo (efecto delivery).
  Future<void> _iniciarSeguimiento() async {
    setState(() {
      _cargandoPermiso = true;
      _permisoDenegado = false;
      _error = null;
    });

    final ok = await _solicitarPermiso();
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _cargandoPermiso = false;
        _permisoDenegado = true;
      });
      return;
    }

    setState(() => _cargandoPermiso = false);

    // distanceFilter ~10 m: el stream emite cuando el tecnico avanza ese tramo,
    // generando el movimiento del marcador en el mapa.
    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );

    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosicion,
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = 'No se pudo obtener la ubicacion del GPS.');
      },
    );
  }

  /// Reutiliza el patron de permisos de location_sender.dart.
  Future<bool> _solicitarPermiso() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  /// Maneja cada nuevo fix del GPS: actualiza el marcador, sigue al tecnico con
  /// la camara y recalcula la ruta cuando corresponde.
  void _onPosicion(Position pos) {
    if (!mounted) return;

    final esPrimerFix = _tecnico == null;
    setState(() {
      _tecnicoLat = pos.latitude;
      _tecnicoLng = pos.longitude;
      _error = null;
    });

    final actual = LatLng(pos.latitude, pos.longitude);

    // Centra/sigue al tecnico cuando llega un nuevo fix.
    _mapController.move(actual, esPrimerFix ? 14.5 : _mapController.camera.zoom);

    // Recalcula al primer fix o cuando se movio mas del umbral respecto al
    // ultimo punto donde se pidio la ruta.
    if (esPrimerFix || _ultimoPuntoRuta == null) {
      _recalcularRuta(actual);
    } else {
      final movidoM = _distanciaMetros(
        _ultimoPuntoRuta!.latitude,
        _ultimoPuntoRuta!.longitude,
        actual.latitude,
        actual.longitude,
      );
      if (movidoM >= _umbralRecalculoM) {
        _recalcularRuta(actual);
      }
    }
  }

  /// Solicita la ruta optima por calles a OSRM; si falla, usa el fallback de
  /// linea recta + haversine.
  Future<void> _recalcularRuta(LatLng desde) async {
    _ultimoPuntoRuta = desde;
    if (_calculandoRuta) return;
    _calculandoRuta = true;

    final cli = _cliente;
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '${desde.longitude},${desde.latitude};'
      '${cli.longitude},${cli.latitude}'
      '?overview=full&geometries=geojson',
    );

    try {
      final resp = await http.get(url).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final rutas = data['routes'] as List<dynamic>?;
        if (data['code'] == 'Ok' && rutas != null && rutas.isNotEmpty) {
          final ruta = rutas.first as Map<String, dynamic>;
          final geometry = ruta['geometry'] as Map<String, dynamic>;
          final coords = geometry['coordinates'] as List<dynamic>;

          // OSRM entrega cada punto como [lng, lat].
          final puntos = coords.map<LatLng>((c) {
            final par = c as List<dynamic>;
            return LatLng(
              (par[1] as num).toDouble(),
              (par[0] as num).toDouble(),
            );
          }).toList();

          final duracionSeg = (ruta['duration'] as num).toDouble();
          final distanciaM = (ruta['distance'] as num).toDouble();

          if (!mounted) return;
          setState(() {
            _ruta = puntos;
            _rutaEsFallback = false;
            _distanciaKm = distanciaM / 1000.0;
            _etaMinutos = math.max(1, (duracionSeg / 60).round());
          });
          _calculandoRuta = false;
          return;
        }
      }
      // Respuesta no valida: cae al fallback.
      _aplicarFallback(desde);
    } catch (_) {
      // OSRM caido o sin red: dibuja la linea recta y estima con haversine.
      _aplicarFallback(desde);
    } finally {
      _calculandoRuta = false;
    }
  }

  /// Fallback sin red/OSRM: linea recta entre tecnico y cliente, distancia por
  /// haversine y ETA simple por velocidad promedio.
  void _aplicarFallback(LatLng desde) {
    if (!mounted) return;
    final cli = _cliente;
    final distanciaKm = _calcularDistanciaKm(
      desde.latitude,
      desde.longitude,
      cli.latitude,
      cli.longitude,
    );
    setState(() {
      _ruta = [desde, cli];
      _rutaEsFallback = true;
      _distanciaKm = distanciaKm;
      _etaMinutos = _estimarMinutosDesdeKm(distanciaKm);
    });
  }

  /// Reintenta tras un error o permiso denegado.
  Future<void> _reintentar() => _iniciarSeguimiento();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Seguimiento #${widget.idIncidente}'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_cargandoPermiso) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_permisoDenegado) {
      return _buildMensaje(
        icono: Icons.location_disabled,
        color: AppColors.amber,
        texto:
            'Necesitamos permiso de ubicacion para mostrar tu posicion y la '
            'ruta hacia el cliente. Activalo e intenta de nuevo.',
      );
    }

    if (_error != null) {
      return _buildMensaje(
        icono: Icons.location_off,
        color: AppColors.amber,
        texto: _error!,
      );
    }

    return Column(
      children: [
        _buildBarraInfo(),
        Expanded(child: _buildMapa()),
        _buildLeyenda(),
      ],
    );
  }

  Widget _buildBarraInfo() {
    final esperandoGps = _tecnico == null;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.brandSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.brand.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.navigation, color: AppColors.brand),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'En camino al cliente',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.brandInk,
                  ),
                ),
                const SizedBox(height: 4),
                if (esperandoGps)
                  const Text('Obteniendo tu ubicacion por GPS...')
                else if (_distanciaKm != null && _etaMinutos != null)
                  Text(
                    'ETA $_etaMinutos min  •  '
                    '${_distanciaKm!.toStringAsFixed(1)} km'
                    '${_rutaEsFallback ? '  (estimado)' : ''}',
                    style: const TextStyle(color: AppColors.ink),
                  )
                else
                  const Text('Calculando ruta...'),
              ],
            ),
          ),
          if (_calculandoRuta)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _buildMapa() {
    final tecnico = _tecnico;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            // Al inicio, si aun no hay GPS, centra en el cliente.
            initialCenter: tecnico ?? _cliente,
            initialZoom: tecnico != null ? 14.5 : 15,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'app.flujo.emergencia',
            ),
            if (_ruta.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _ruta,
                    strokeWidth: 5,
                    color: _rutaEsFallback
                        ? AppColors.inkMuted
                        : AppColors.indigo,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                // Cliente (incidente): pin rojo de marca.
                Marker(
                  point: _cliente,
                  width: 46,
                  height: 46,
                  child: const Icon(
                    Icons.location_on,
                    color: AppColors.danger,
                    size: 42,
                  ),
                ),
                // Tecnico: icono de vehiculo en su posicion viva, con buen
                // contraste sobre el mapa.
                if (tecnico != null)
                  Marker(
                    point: tecnico,
                    width: 46,
                    height: 46,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.indigo,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: AppColors.shadowMd,
                      ),
                      padding: const EdgeInsets.all(6),
                      child: const Icon(
                        Icons.navigation,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeyenda() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Leyenda:'),
          const SizedBox(height: 6),
          Row(
            children: const [
              Icon(Icons.location_on, color: AppColors.danger),
              SizedBox(width: 6),
              Text('Cliente (incidente)'),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: const [
              Icon(Icons.navigation, color: AppColors.indigo),
              SizedBox(width: 6),
              Text('Tu ubicacion (en vivo)'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMensaje({
    required IconData icono,
    required Color color,
    required String texto,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 64, color: color),
            const SizedBox(height: 12),
            Text(texto, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _reintentar,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  // Distancia en metros (haversine) para decidir el recalculo de ruta.
  double _distanciaMetros(double lat1, double lon1, double lat2, double lon2) {
    return _calcularDistanciaKm(lat1, lon1, lat2, lon2) * 1000.0;
  }

  // Helper haversine conservado para el fallback y el control de recalculo.
  double _calcularDistanciaKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double radioTierraKm = 6371.0;
    final dLat = _gradosARadianes(lat2 - lat1);
    final dLon = _gradosARadianes(lon2 - lon1);
    final a =
        (math.sin(dLat / 2) * math.sin(dLat / 2)) +
            math.cos(_gradosARadianes(lat1)) *
                math.cos(_gradosARadianes(lat2)) *
                (math.sin(dLon / 2) * math.sin(dLon / 2));
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return radioTierraKm * c;
  }

  int _estimarMinutosDesdeKm(double distanciaKm) {
    // Velocidad promedio urbana para el fallback (~25-40 km/h).
    const double velocidadPromedioKmh = 30.0;
    final horas = distanciaKm / velocidadPromedioKmh;
    final minutos = (horas * 60).round();
    return minutos < 1 ? 1 : minutos;
  }

  double _gradosARadianes(double grados) =>
      grados * (3.141592653589793 / 180.0);
}
