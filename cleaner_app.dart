import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

class CleanerApp extends StatelessWidget {
  const CleanerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hygiene Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, primarySwatch: Colors.blue),
      home: const CleanerHome(),
    );
  }
}

class CleanerHome extends StatefulWidget {
  const CleanerHome({super.key});

  @override
  State<CleanerHome> createState() => _CleanerHomeState();
}

class _CleanerHomeState extends State<CleanerHome> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = const [
      CleanerDashboardPage(),
      CleanerNotificationsPage(),
      CleanerHistoryPage(),
    ];

    return Scaffold(
      body: pages[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard),
            label: "Dashboard",
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications),
            label: "Alerts",
          ),
          NavigationDestination(icon: Icon(Icons.history), label: "History"),
        ],
      ),
    );
  }
}

// ============================================================
// ✅ DASHBOARD PAGE
// ============================================================

class CleanerDashboardPage extends StatefulWidget {
  const CleanerDashboardPage({super.key});

  @override
  State<CleanerDashboardPage> createState() => _CleanerDashboardPageState();
}

class _CleanerDashboardPageState extends State<CleanerDashboardPage> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  List<WashroomData> _washrooms = [];
  bool _isLoading = true;

  StreamSubscription<DatabaseEvent>? _sub;

  String _searchText = "";
  bool _onlyCritical = false;

  // ✅ Prevent multiple click + show loader on button
  final Set<String> _cleaningInProgressIds = {};

  @override
  void initState() {
    super.initState();
    _listenWashroomsRealtime();
  }

  void _listenWashroomsRealtime() {
    setState(() => _isLoading = true);

    _sub = _db
        .child("washrooms")
        .onValue
        .listen(
          (event) {
            final value = event.snapshot.value;

            if (value == null) {
              setState(() {
                _washrooms = [];
                _isLoading = false;
              });
              return;
            }

            final washroomMap = Map<String, dynamic>.from(value as Map);
            final List<WashroomData> list = [];

            washroomMap.forEach((washroomId, data) {
              if (data == null) return;

              final washroom = data is Map
                  ? Map<String, dynamic>.from(data)
                  : {};

              // ✅ Only show active washrooms
              final status = (washroom["status"] ?? "")
                  .toString()
                  .toLowerCase();
              if (status != "active") return;

              final currentRaw = washroom["current"];
              final current = currentRaw is Map
                  ? Map<String, dynamic>.from(currentRaw)
                  : {};

              final anomaliesRaw = current["anomalies"];
              final anomalies = anomaliesRaw is List
                  ? List<Map<String, dynamic>>.from(
                      anomaliesRaw.map(
                        (e) => e is Map ? Map<String, dynamic>.from(e) : {},
                      ),
                    )
                  : <Map<String, dynamic>>[];

              list.add(
                WashroomData(
                  id: washroomId,
                  name: washroom["name"] ?? "Washroom $washroomId",
                  location: washroom["location"] ?? "Unknown",
                  score: (current["score"] ?? 0).toDouble(),
                  timestamp: current["timestamp"]?.toString() ?? "",
                  anomalies: anomalies,
                ),
              );
            });

            // ✅ Lowest score first
            list.sort((a, b) => a.score.compareTo(b.score));

            setState(() {
              _washrooms = list;
              _isLoading = false;
            });
          },
          onError: (e) {
            debugPrint("Washroom realtime error: $e");
            setState(() => _isLoading = false);
          },
        );
  }

  Color _scoreColor(double score) {
    if (score >= 70) return Colors.green;
    if (score >= 50) return Colors.orange;
    return Colors.red;
  }

  bool _isCleaning(String washroomId) =>
      _cleaningInProgressIds.contains(washroomId);

  // ✅ FINAL MARK CLEANED (WITH OVERRIDE + LAST_CLEANED + HISTORY)
  Future<void> _markCleaned(WashroomData data) async {
    if (_isCleaning(data.id)) return;

    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Confirm Cleaning"),
        content: Text("Mark ${data.name} as cleaned?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Confirm"),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _cleaningInProgressIds.add(data.id));

    try {
      final nowIso = DateTime.now().toIso8601String();
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // ✅ 1) stop esp32 overwrite for 30 sec
      await _db.child("washrooms/${data.id}/override").set({
        "active": true,
        "until": nowSec + 30,
      });

      // ✅ 2) update last_cleaned
      await _db.child("washrooms/${data.id}/last_cleaned").set({
        "cleaner": "Cleaner App",
        "timestamp": nowIso,
      });

      // ✅ 3) reset current
      await _db.child("washrooms/${data.id}/current").update({
        "score": 100,
        "timestamp": nowIso,
        "status": "CLEANED",
        "presence": 1,
        "anomalies": [],
        "component_scores": {
          "air_quality": 100,
          "floor_moisture": 100,
          "humidity": 100,
          "temperature": 100,
        },
      });

      // ✅ 4) cleaning history
      await _db.child("cleaning_history").push().set({
        "washroom_id": data.id,
        "washroom_name": data.name,
        "location": data.location,
        "timestamp": nowIso,
        "done_by": "Cleaner App",
      });

      // ✅ 5) notifications log
      await _db.child("notifications").push().set({
        "washroom_id": data.id,
        "message": "✅ ${data.name} cleaned successfully",
        "timestamp": nowIso,
        "type": "CLEANED",
        "score": 100,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("✅ ${data.name} cleaned! (ESP32 paused 30s)"),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      debugPrint("Mark Cleaned Error: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("❌ Failed: $e"), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _cleaningInProgressIds.remove(data.id));
    }
  }

  List<WashroomData> get _filteredWashrooms {
    var list = _washrooms;

    if (_onlyCritical) {
      list = list.where((w) => w.score < 50).toList();
    }

    if (_searchText.trim().isNotEmpty) {
      final q = _searchText.trim().toLowerCase();
      list = list.where((w) {
        return w.id.toLowerCase().contains(q) ||
            w.name.toLowerCase().contains(q) ||
            w.location.toLowerCase().contains(q);
      }).toList();
    }

    return list;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredWashrooms;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Cleaner Dashboard"),
        actions: [
          IconButton(
            onPressed: () => setState(() => _onlyCritical = !_onlyCritical),
            icon: Icon(_onlyCritical ? Icons.filter_alt : Icons.filter_alt_off),
            tooltip: _onlyCritical ? "Critical Only" : "Show Critical",
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              onChanged: (v) => setState(() => _searchText = v),
              decoration: InputDecoration(
                hintText: "Search washroom (name/location/id)",
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                ? const Center(
                    child: Text(
                      "No washrooms found",
                      style: TextStyle(fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    itemCount: filtered.length,
                    padding: const EdgeInsets.all(10),
                    itemBuilder: (context, index) {
                      final w = filtered[index];
                      final color = _scoreColor(w.score);
                      final cleaning = _isCleaning(w.id);

                      return Card(
                        elevation: 2,
                        margin: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 5,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    WashroomDetailPage(washroomId: w.id),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: color.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(
                                        Icons.wc,
                                        color: color,
                                        size: 28,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            w.name,
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            w.location,
                                            style: TextStyle(
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            "ID: ${w.id}",
                                            style: TextStyle(
                                              color: Colors.grey[600],
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          "${w.score.toInt()}%",
                                          style: TextStyle(
                                            fontSize: 28,
                                            fontWeight: FontWeight.bold,
                                            color: color,
                                          ),
                                        ),
                                        Text(
                                          w.score >= 70
                                              ? "Good"
                                              : w.score >= 50
                                              ? "Fair"
                                              : "Critical",
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: color,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                if (w.anomalies.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Colors.red.withOpacity(0.25),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.warning,
                                              color: Colors.red,
                                              size: 18,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              "${w.anomalies.length} Issues",
                                              style: const TextStyle(
                                                color: Colors.red,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        ...w.anomalies.take(2).map((a) {
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              left: 26,
                                            ),
                                            child: Text(
                                              "• ${a["message"] ?? ""}",
                                              style: TextStyle(
                                                color: Colors.red[700],
                                                fontSize: 12,
                                              ),
                                            ),
                                          );
                                        }),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _formatAgo(w.timestamp),
                                      style: const TextStyle(
                                        color: Colors.grey,
                                        fontSize: 12,
                                      ),
                                    ),
                                    ElevatedButton(
                                      onPressed: cleaning
                                          ? null
                                          : () => _markCleaned(w),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: color,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                        ),
                                      ),
                                      child: cleaning
                                          ? const SizedBox(
                                              height: 18,
                                              width: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : Row(
                                              children: const [
                                                Icon(
                                                  Icons.cleaning_services,
                                                  size: 18,
                                                ),
                                                SizedBox(width: 8),
                                                Text("Mark Cleaned"),
                                              ],
                                            ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatAgo(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp);
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inMinutes < 1) return "Just now";
      if (diff.inMinutes < 60) return "${diff.inMinutes} min ago";
      if (diff.inHours < 24) return "${diff.inHours} hr ago";
      return "${diff.inDays} days ago";
    } catch (_) {
      return "Unknown";
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ============================================================
// ✅ NOTIFICATIONS PAGE
// ============================================================

class CleanerNotificationsPage extends StatefulWidget {
  const CleanerNotificationsPage({super.key});

  @override
  State<CleanerNotificationsPage> createState() =>
      _CleanerNotificationsPageState();
}

class _CleanerNotificationsPageState extends State<CleanerNotificationsPage> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  final List<NotificationData> _notifications = [];
  StreamSubscription<DatabaseEvent>? _sub;

  @override
  void initState() {
    super.initState();

    _sub = _db.child("notifications").onChildAdded.listen((event) {
      final v = event.snapshot.value;
      if (v == null) return;

      final data = Map<String, dynamic>.from(v as Map);

      setState(() {
        _notifications.insert(
          0,
          NotificationData(
            id: event.snapshot.key ?? "",
            washroomId: data["washroom_id"]?.toString() ?? "",
            message: data["message"]?.toString() ?? "",
            timestamp: data["timestamp"]?.toString() ?? "",
            type: data["type"]?.toString() ?? "INFO",
            score: (data["score"] ?? 0).toDouble(),
          ),
        );

        if (_notifications.length > 60) {
          _notifications.removeLast();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Notifications")),
      body: _notifications.isEmpty
          ? const Center(child: Text("No alerts"))
          : ListView.builder(
              itemCount: _notifications.length,
              itemBuilder: (_, i) {
                final n = _notifications[i];
                final isAlert = n.type == "HYGIENE_ALERT";

                return ListTile(
                  leading: Icon(
                    isAlert ? Icons.warning : Icons.info,
                    color: isAlert ? Colors.red : Colors.blue,
                  ),
                  title: Text(n.message),
                  subtitle: Text("Washroom: ${n.washroomId}"),
                  trailing: Text(_timeOnly(n.timestamp)),
                );
              },
            ),
    );
  }

  String _timeOnly(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp);
      return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } catch (_) {
      return "";
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ============================================================
// ✅ CLEANING HISTORY PAGE
// ============================================================

class CleanerHistoryPage extends StatefulWidget {
  const CleanerHistoryPage({super.key});

  @override
  State<CleanerHistoryPage> createState() => _CleanerHistoryPageState();
}

class _CleanerHistoryPageState extends State<CleanerHistoryPage> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  final List<CleaningHistory> _history = [];
  StreamSubscription<DatabaseEvent>? _sub;

  @override
  void initState() {
    super.initState();

    _sub = _db.child("cleaning_history").onChildAdded.listen((event) {
      final v = event.snapshot.value;
      if (v == null) return;

      final data = Map<String, dynamic>.from(v as Map);

      setState(() {
        _history.insert(
          0,
          CleaningHistory(
            washroomId: data["washroom_id"]?.toString() ?? "",
            washroomName: data["washroom_name"]?.toString() ?? "",
            location: data["location"]?.toString() ?? "",
            timestamp: data["timestamp"]?.toString() ?? "",
            doneBy: data["done_by"]?.toString() ?? "",
          ),
        );

        if (_history.length > 80) {
          _history.removeLast();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Cleaning History")),
      body: _history.isEmpty
          ? const Center(child: Text("No cleaning logs yet"))
          : ListView.builder(
              itemCount: _history.length,
              itemBuilder: (_, i) {
                final h = _history[i];
                return ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green),
                  title: Text(
                    h.washroomName.isEmpty ? h.washroomId : h.washroomName,
                  ),
                  subtitle: Text("${h.location}\n${h.doneBy}"),
                  isThreeLine: true,
                  trailing: Text(_timeOnly(h.timestamp)),
                );
              },
            ),
    );
  }

  String _timeOnly(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp);
      return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } catch (_) {
      return "";
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ============================================================
// ✅ DETAIL PAGE
// ============================================================

class WashroomDetailPage extends StatelessWidget {
  final String washroomId;
  const WashroomDetailPage({super.key, required this.washroomId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Washroom Details")),
      body: StreamBuilder(
        stream: FirebaseDatabase.instance
            .ref("washrooms/$washroomId/current")
            .onValue,
        builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final val = snapshot.data?.snapshot.value;
          if (val == null) {
            return const Center(child: Text("No data available"));
          }

          final data = Map<String, dynamic>.from(val as Map);

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(data.toString(), style: const TextStyle(fontSize: 14)),
          );
        },
      ),
    );
  }
}

// ============================================================
// ✅ MODELS
// ============================================================

class WashroomData {
  final String id;
  final String name;
  final String location;
  final double score;
  final String timestamp;
  final List<Map<String, dynamic>> anomalies;

  WashroomData({
    required this.id,
    required this.name,
    required this.location,
    required this.score,
    required this.timestamp,
    required this.anomalies,
  });
}

class NotificationData {
  final String id;
  final String washroomId;
  final String message;
  final String timestamp;
  final String type;
  final double score;

  NotificationData({
    required this.id,
    required this.washroomId,
    required this.message,
    required this.timestamp,
    required this.type,
    required this.score,
  });
}

class CleaningHistory {
  final String washroomId;
  final String washroomName;
  final String location;
  final String timestamp;
  final String doneBy;

  CleaningHistory({
    required this.washroomId,
    required this.washroomName,
    required this.location,
    required this.timestamp,
    required this.doneBy,
  });
}
