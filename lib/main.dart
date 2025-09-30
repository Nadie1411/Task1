// A single-file Flutter application for indoor navigation using real-world movement.
// It uses phone sensors for step detection/direction, provides voice feedback,
// and integrates with Firebase Firestore for persistent data.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:sensors_plus/sensors_plus.dart';

// Assuming you have a file named 'firebase_options.dart'
import 'firebase_options.dart';

// Enum to represent the state of each cell in the grid.
enum CellType { empty, wall, start, end, path }

// A class to represent a node in the pathfinding graph.
class Node {
  final int x;
  final int y;
  double gCost = double.infinity;
  double hCost = double.infinity;
  Node? parent;

  Node(this.x, this.y);

  double get fCost => gCost + hCost;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is Node &&
              runtimeType == other.runtimeType &&
              x == other.x &&
              y == other.y;

  @override
  int get hashCode => x.hashCode ^ y.hashCode;
}

// The main application widget.
class IndoorNavigationApp extends StatefulWidget {
  const IndoorNavigationApp({super.key});

  @override
  State<IndoorNavigationApp> createState() => _IndoorNavigationAppState();
}

class _IndoorNavigationAppState extends State<IndoorNavigationApp> {
  // Global variables provided by the canvas environment.
  static const String appId = String.fromEnvironment('appId', defaultValue: 'default-app-id');
  static const String initialAuthToken = String.fromEnvironment('initialAuthToken', defaultValue: '');

  static const int gridSize = 20;
  static const double cellSize = 40.0;
  static const double imageSize = gridSize * cellSize;

  // Firebase services
  late FirebaseFirestore db;
  late FirebaseAuth auth;
  String? userId;

  // Application state
  List<List<int>> gridData = List.generate(gridSize, (_) => List.filled(gridSize, 0));
  Offset? start;
  Offset? end;
  Offset? currentLocation;
  List<Offset> path = [];

  bool isAuthReady = false;
  bool useAStar = true;
  bool isNavigating = false;

  // Sensor and TTS state
  late FlutterTts flutterTts;
  StreamSubscription? _magnetometerSubscription;
  StreamSubscription? _accelerometerSubscription;
  double _heading = 0.0;
  int _stepCount = 0;
  final double _stepThreshold = 11.5; // Tune this value based on device sensitivity
  bool _isPeak = false;
  DateTime _lastStepTime = DateTime.now();


  @override
  void initState() {
    super.initState();
    _initializeFirebase();
    _initializeSensorsAndTts();
  }

  @override
  void dispose() {
    _stopNavigation();
    _magnetometerSubscription?.cancel();
    _accelerometerSubscription?.cancel();
    super.dispose();
  }

  // Initializes Firebase and authenticates the user.
  Future<void> _initializeFirebase() async {
    try {
      db = FirebaseFirestore.instance;
      auth = FirebaseAuth.instance;

      if (initialAuthToken.isNotEmpty) {
        await auth.signInWithCustomToken(initialAuthToken);
      } else {
        await auth.signInAnonymously();
      }

      auth.authStateChanges().listen((user) {
        if (user != null) {
          setState(() {
            userId = user.uid;
            isAuthReady = true;
          });
          _listenToData();
        } else {
          setState(() {
            isAuthReady = false;
          });
        }
      });
    } catch (e) {
      print("Failed to initialize Firebase: $e");
    }
  }

  // Initializes sensors and Text-to-Speech engine.
  void _initializeSensorsAndTts() {
    flutterTts = FlutterTts();

    _magnetometerSubscription = magnetometerEventStream().listen((MagnetometerEvent event) {
      final double angle = math.atan2(event.y, event.x);
      double degrees = angle * (180 / math.pi);
      setState(() {
        _heading = (degrees + 360) % 360;
      });
    });

    _accelerometerSubscription = accelerometerEventStream(samplingPeriod: SensorInterval.normalInterval)
        .listen((AccelerometerEvent event) {
      double magnitude = math.sqrt(math.pow(event.x, 2) + math.pow(event.y, 2) + math.pow(event.z, 2));

      if (magnitude > _stepThreshold && !_isPeak) {
        if (DateTime.now().difference(_lastStepTime) > const Duration(milliseconds: 300)) {
          _lastStepTime = DateTime.now();
          _onStepDetected();
        }
        _isPeak = true;
      } else if (magnitude < _stepThreshold) {
        _isPeak = false;
      }
    });
  }

  // Helper function to provide voice feedback.
  Future<void> _speak(String text) async {
    await flutterTts.speak(text);
  }

  // Core logic executed when a physical step is detected.
  void _onStepDetected() {
    if (!isNavigating || currentLocation == null) return;

    setState(() {
      _stepCount++;
    });

    final currentGridX = (currentLocation!.dx / cellSize).floor();
    final currentGridY = (currentLocation!.dy / cellSize).floor();
    int nextGridX = currentGridX;
    int nextGridY = currentGridY;

    if (_heading > 315 || _heading <= 45) nextGridY--; // Move Up
    else if (_heading > 45 && _heading <= 135) nextGridX++; // Move Right
    else if (_heading > 135 && _heading <= 225) nextGridY++; // Move Down
    else if (_heading > 225 && _heading <= 315) nextGridX--; // Move Left

    if (nextGridX < 0 || nextGridX >= gridSize || nextGridY < 0 || nextGridY >= gridSize) {
      _speak("Boundary reached");
      return;
    }
    if (gridData[nextGridY][nextGridX] == 1) {
      _speak("Wall ahead");
      return;
    }

    final newLocation = Offset(nextGridX * cellSize + cellSize / 2, nextGridY * cellSize + cellSize / 2);
    _updateUserLocation(newLocation);

    if (path.isNotEmpty && newLocation == path.last) {
      _speak("You have arrived at your destination!");
      _stopNavigation();
      return;
    }

    _giveNextInstruction();
  }

  // Provides voice guidance based on the path.
  void _giveNextInstruction() {
    if (path.isEmpty || currentLocation == null) return;

    int currentIndex = path.indexWhere((offset) => offset == currentLocation);
    if (currentIndex == -1 || currentIndex + 1 >= path.length) return;

    Offset nextPoint = path[currentIndex + 1];
    Offset currentPoint = currentLocation!;

    double angleToNextPoint = (math.atan2(nextPoint.dy - currentPoint.dy, nextPoint.dx - currentPoint.dx) * (180 / math.pi) + 360) % 360;

    double requiredHeading = (angleToNextPoint - 90) * -1;
    if(requiredHeading < 0) requiredHeading += 360;

    double headingDifference = requiredHeading - _heading;
    if (headingDifference > 180) headingDifference -= 360;
    if (headingDifference < -180) headingDifference += 360;

    if (headingDifference.abs() < 30) {
      _speak("Continue straight");
    } else if (headingDifference > 30 && headingDifference < 150) {
      _speak("Turn right");
    } else if (headingDifference < -30 && headingDifference > -150) {
      _speak("Turn left");
    } else {
      _speak("Turn around");
    }
  }

  // Sets up Firestore listeners to update local state in real-time.
  void _listenToData() {
    if (userId == null) return;

    db.collection('artifacts').doc(appId).collection('users').doc(userId).snapshots().listen((snapshot) {
      if (snapshot.exists) {
        final data = snapshot.data();
        if (data != null) {
          setState(() {
            final startMap = data['start'] as Map<String, dynamic>?;
            final endMap = data['end'] as Map<String, dynamic>?;
            final locationMap = data['currentLocation'] as Map<String, dynamic>?;
            final pathList = data['path'] as List<dynamic>?;

            start = startMap != null ? Offset(startMap['dx'] as double, startMap['dy'] as double) : null;
            end = endMap != null ? Offset(endMap['dx'] as double, endMap['dy'] as double) : null;
            currentLocation = locationMap != null ? Offset(locationMap['dx'] as double, locationMap['dy'] as double) : null;

            path = pathList != null
                ? pathList.map((p) => Offset(p['dx'] as double, p['dy'] as double)).toList()
                : [];
          });
        }
      }
    });

    db.collection('artifacts').doc(appId).collection('users').doc(userId).collection('map_data').doc('grid').snapshots().listen((snapshot) {
      if (snapshot.exists) {
        final data = snapshot.data();
        if (data != null && data['grid'] is String) {
          final decoded = jsonDecode(data['grid'] as String);
          if (decoded is List) {
            setState(() {
              gridData = decoded.map((row) => (row as List).cast<int>()).toList();
            });
          }
        }
      } else {
        _createDefaultGrid();
      }
    });
  }

  // Creates a default grid and saves it to Firestore.
  Future<void> _createDefaultGrid() async {
    if (userId == null) return;
    final defaultGrid = List.generate(gridSize, (_) => List.filled(gridSize, 0));
    for (int i = 5; i < 15; i++) {
      defaultGrid[8][i] = 1;
      defaultGrid[i][12] = 1;
    }

    await db.collection('artifacts').doc(appId).collection('users').doc(userId).collection('map_data').doc('grid').set({
      'grid': jsonEncode(defaultGrid),
    });
  }

  // Updates the user's location in Firestore.
  Future<void> _updateUserLocation(Offset newLocation) async {
    if (userId == null) return;
    final locationMap = {'dx': newLocation.dx, 'dy': newLocation.dy};

    await db.collection('artifacts').doc(appId).collection('users').doc(userId).set(
      {'currentLocation': locationMap},
      SetOptions(merge: true),
    );
  }

  // Handles long press to set start and end points.
  Future<void> _setPoint(Offset position) async {
    if (userId == null) return;
    _stopNavigation();

    final gridX = (position.dx / cellSize).floor();
    final gridY = (position.dy / cellSize).floor();
    final newPosition = Offset(gridX * cellSize + cellSize / 2, gridY * cellSize + cellSize / 2);

    Map<String, dynamic> updateData = {};
    if (start == null) {
      updateData['start'] = {'dx': newPosition.dx, 'dy': newPosition.dy};
      updateData['end'] = null;
    } else if (end == null) {
      updateData['end'] = {'dx': newPosition.dx, 'dy': newPosition.dy};
    } else {
      updateData['start'] = {'dx': newPosition.dx, 'dy': newPosition.dy};
      updateData['end'] = null;
    }

    await db.collection('artifacts').doc(appId).collection('users').doc(userId).set(
      updateData,
      SetOptions(merge: true),
    );
    _findAndSavePath();
  }

  // Finds the path and saves it to Firestore.
  void _findAndSavePath() async {
    if (start == null || end == null || userId == null) return;
    final startNode = Node((start!.dx / cellSize).floor(), (start!.dy / cellSize).floor());
    final endNode = Node((end!.dx / cellSize).floor(), (end!.dy / cellSize).floor());

    List<Node>? calculatedPath;
    if (useAStar) {
      calculatedPath = aStarAlgorithm(startNode, endNode);
    } else {
      calculatedPath = dijkstraAlgorithm(startNode, endNode);
    }

    List<Map<String, double>> pathPoints = [];
    if (calculatedPath != null) {
      pathPoints = calculatedPath.map((node) => {
        'dx': (node.x * cellSize) + (cellSize / 2),
        'dy': (node.y * cellSize) + (cellSize / 2),
      }).toList();
    } else {
      _speak("No path could be found to the destination.");
    }

    await db.collection('artifacts').doc(appId).collection('users').doc(userId).set(
      {'path': pathPoints},
      SetOptions(merge: true),
    );
  }

  // A* algorithm implementation.
  List<Node>? aStarAlgorithm(Node startNode, Node endNode) {
    var openSet = PriorityQueue<Node>((a, b) => a.fCost.compareTo(b.fCost));
    var closedSet = <Node>{};

    startNode.gCost = 0;
    startNode.hCost = manhattanDistance(startNode, endNode);
    openSet.add(startNode);

    while (openSet.isNotEmpty) {
      var currentNode = openSet.removeFirst();
      if (currentNode == endNode) {
        return _reconstructPath(currentNode);
      }
      closedSet.add(currentNode);

      for (var neighbor in _getNeighbors(currentNode)) {
        if (closedSet.contains(neighbor) || gridData[neighbor.y][neighbor.x] == 1) {
          continue;
        }

        double newGCost = currentNode.gCost + 1;
        if (newGCost < neighbor.gCost) {
          neighbor.gCost = newGCost;
          neighbor.hCost = manhattanDistance(neighbor, endNode);
          neighbor.parent = currentNode;
          if (!openSet.contains(neighbor)) {
            openSet.add(neighbor);
          }
        }
      }
    }
    return null;
  }

  // Dijkstra's algorithm implementation.
  List<Node>? dijkstraAlgorithm(Node startNode, Node endNode) {
    var openSet = PriorityQueue<Node>((a, b) => a.gCost.compareTo(b.gCost));
    startNode.gCost = 0;
    openSet.add(startNode);

    var allNodes = <String, Node>{};
    for (int y = 0; y < gridSize; y++) {
      for (int x = 0; x < gridSize; x++) {
        if (gridData[y][x] == 0) {
          var node = Node(x, y);
          allNodes['${node.x},${node.y}'] = node;
        }
      }
    }

    while (openSet.isNotEmpty) {
      var currentNode = openSet.removeFirst();

      if (currentNode == endNode) {
        return _reconstructPath(currentNode);
      }

      for (var neighborPos in _getNeighbors(currentNode)) {
        if (gridData[neighborPos.y][neighborPos.x] == 1) {
          continue;
        }

        var neighbor = allNodes['${neighborPos.x},${neighborPos.y}'] ?? Node(neighborPos.x, neighborPos.y);
        double newGCost = currentNode.gCost + 1;
        if (newGCost < neighbor.gCost) {
          neighbor.gCost = newGCost;
          neighbor.parent = currentNode;
          if (!openSet.contains(neighbor)) {
            openSet.add(neighbor);
          }
        }
      }
    }
    return null;
  }

  // Reconstructs the path from the end node.
  List<Node> _reconstructPath(Node endNode) {
    List<Node> path = [];
    Node? currentNode = endNode;
    while (currentNode != null) {
      path.add(currentNode);
      currentNode = currentNode.parent;
    }
    return path.reversed.toList();
  }

  // Returns valid neighbors of a given node.
  // ***** THIS IS THE CORRECTED FUNCTION *****
  List<Node> _getNeighbors(Node node) {
    List<Node> neighbors = [];
    int x = node.x;
    int y = node.y;
    // Only cardinal directions for simpler navigation instructions
    final List<List<int>> dxDyPairs = [[0, -1], [0, 1], [-1, 0], [1, 0]]; // Up, Down, Left, Right

    for (final pair in dxDyPairs) {
      final int newX = x + pair[0];
      final int newY = y + pair[1];
      if (newX >= 0 && newX < gridSize && newY >= 0 && newY < gridSize) {
        neighbors.add(Node(newX, newY));
      }
    }
    return neighbors;
  }

  // Manhattan distance heuristic for A*.
  double manhattanDistance(Node a, Node b) {
    return (a.x - b.x).abs() + (a.y - b.y).abs().toDouble();
  }

  // Starts the navigation, now with voice.
  void _startNavigation() {
    if (path.isEmpty) {
      _speak("Please set a start and end point first.");
      return;
    }
    setState(() {
      isNavigating = true;
      _stepCount = 0;
    });
    _updateUserLocation(path.first);
    _speak("Navigation started.");
    _giveNextInstruction();
  }

  // Stops the navigation, now with voice.
  void _stopNavigation() {
    if (isNavigating) {
      _speak("Navigation stopped.");
    }
    setState(() {
      isNavigating = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!isAuthReady) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Indoor Navigation'),
          backgroundColor: Colors.indigo,
        ),
        body: SingleChildScrollView(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 10),
                Text(
                  isNavigating ? 'Navigation in progress...' : 'Navigation is stopped.',
                  style: TextStyle(fontSize: 16, color: isNavigating ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
                ),
                Text('Heading: ${_heading.toStringAsFixed(1)}°, Steps: $_stepCount', style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 10),
                Container(
                  width: imageSize,
                  height: imageSize,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black, width: 2),
                    color: Colors.grey[200],
                  ),
                  child: Stack(
                    children: [
                      CustomPaint(
                        painter: GridPainter(gridData: gridData, cellSize: cellSize),
                        child: GestureDetector(
                          onLongPressStart: (details) => _setPoint(details.localPosition),
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                      if (path.isNotEmpty) CustomPaint(painter: PathPainter(path: path)),
                      if (currentLocation != null)
                        Positioned(
                          left: currentLocation!.dx - (cellSize / 2),
                          top: currentLocation!.dy - (cellSize / 2),
                          child: Container(
                            width: cellSize,
                            height: cellSize,
                            decoration: const BoxDecoration(color: Colors.purple, shape: BoxShape.circle),
                          ),
                        ),
                      if (start != null)
                        Positioned(
                          left: start!.dx - (cellSize / 2),
                          top: start!.dy - (cellSize / 2),
                          child: Container(
                            width: cellSize,
                            height: cellSize,
                            decoration: BoxDecoration(color: Colors.green.withOpacity(0.8), shape: BoxShape.circle),
                          ),
                        ),
                      if (end != null)
                        Positioned(
                          left: end!.dx - (cellSize / 2),
                          top: end!.dy - (cellSize / 2),
                          child: Container(
                            width: cellSize,
                            height: cellSize,
                            decoration: BoxDecoration(color: Colors.red.withOpacity(0.8), shape: BoxShape.circle),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: isNavigating ? _stopNavigation : _startNavigation,
                      icon: Icon(isNavigating ? Icons.stop : Icons.play_arrow),
                      label: Text(isNavigating ? 'Stop Navigation' : 'Start Navigation'),
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
                    ),
                    ElevatedButton.icon(
                      onPressed: () {
                        setState(() => useAStar = !useAStar);
                        _findAndSavePath();
                        _speak("Using ${useAStar ? 'A Star' : 'Dijkstra'} algorithm.");
                      },
                      icon: const Icon(Icons.swap_horiz),
                      label: Text(useAStar ? 'A*' : 'Dijkstra'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Instructions:', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text('• A sighted person can long-press on the map to set Start (Green) and End (Red) points.'),
                      Text('• Tap "Start Navigation" to begin receiving voice commands.'),
                      Text('• Walk while holding your phone to move your location on the map.'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// A custom painter to draw the wall grid.
class GridPainter extends CustomPainter {
  final List<List<int>> gridData;
  final double cellSize;

  GridPainter({required this.gridData, required this.cellSize});

  @override
  void paint(Canvas canvas, Size size) {
    final wallPaint = Paint()..color = Colors.black.withOpacity(0.4);

    for (int y = 0; y < gridData.length; y++) {
      for (int x = 0; x < gridData[y].length; x++) {
        if (gridData[y][x] == 1) {
          canvas.drawRect(
            Rect.fromLTWH(x * cellSize, y * cellSize, cellSize, cellSize),
            wallPaint,
          );
        }
      }
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// A custom painter to draw the path line.
class PathPainter extends CustomPainter {
  final List<Offset> path;

  PathPainter({required this.path});

  @override
  void paint(Canvas canvas, Size size) {
    if (path.isEmpty) return;

    final pathPaint = Paint()
      ..color = Colors.blue.withOpacity(0.7)
      ..strokeWidth = 5.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final pathObject = Path();
    pathObject.moveTo(path.first.dx, path.first.dy);
    for (int i = 1; i < path.length; i++) {
      pathObject.lineTo(path[i].dx, path[i].dy);
    }

    canvas.drawPath(pathObject, pathPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// A simple priority queue implementation for the A* algorithm.
class PriorityQueue<E> {
  final List<E> _list = [];
  final Comparator<E> _comparator;

  PriorityQueue(this._comparator);

  void add(E element) {
    _list.add(element);
    _list.sort( _comparator);
  }

  E removeFirst() {
    if (_list.isEmpty) {
      throw StateError('PriorityQueue is empty');
    }
    return _list.removeAt(0);
  }

  bool get isEmpty => _list.isEmpty;
  bool get isNotEmpty => _list.isNotEmpty;

  bool contains(E element) => _list.contains(element);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const IndoorNavigationApp());
}