import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reorderables/reorderables.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'timezone_helper.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:permission_handler/permission_handler.dart';

Future<void> requestNotificationPermission() async {
  final status = await Permission.notification.request();
  if (status.isGranted) {
    print("Notification permission granted");
  } else if (status.isDenied) {
    print("Notification permission denied");
  } else if (status.isPermanentlyDenied) {
    print("Notification permission permanently denied. Opening app settings...");
    await openAppSettings();
  }
}

Future<void> requestCamPermission() async {
  final status = await Permission.camera.request();
  if (status.isGranted) {
    print("Camera permission granted");
  } else if (status.isDenied) {
    print("Camera permission denied");
  } else if (status.isPermanentlyDenied) {
    print("Camera permission permanently denied. Opening app settings...");
    await openAppSettings();
  }
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeTimeZones();

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  final InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  await requestNotificationPermission();
  await requestCamPermission();

  runApp(const MyApp());
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MyAppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'OCR Demo',
        theme: ThemeData(
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.grey,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
              elevation: 4,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            ),
          ),
        ),
        home: const MyHomePage(),
      ),
    );
  }
}

class MyAppState extends ChangeNotifier {
  File? currentImage;
  String extractedText = "";
  List<List<dynamic>> items = [];
  List<List<dynamic>> allItems = [];
  String additionalDetailsText = "";
  final ImagePicker _picker = ImagePicker();
  String recipe = "";
  Future<void> generateRecipe() async {

      String combinedString = allItems.map((item) {
        final name = item[0].toString();
        final date = item[1] as DateTime;
        final formattedDate = "${date.year}-${date.month.toString().padLeft(2,'0')}-${date.day.toString().padLeft(2,'0')}";
        return "$name - $formattedDate";
      }).join(', ');

      final url = Uri.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent");

      final headers = {
        "Content-Type": "application/json",
        "X-goog-api-key": "AIzaSyDSXOH8xyUtOzPi4A_RS-kq4smR6kk7dEs",
      };
      final body = jsonEncode({
      "contents": [
        {
          "parts": [
            {
              "text":
                  "Below is a grocery list of items and their expiration dates. Priorizing those with early expiry dates, generate a healthy recipe including some of the items - ensure that meal is appetizing and do not include items that do not pair well - you can include common household ingredients not explicitly stated DO NOT mention expiry dates:\n$combinedString\n Additionally, attempt to follow these instructions in your recipe: $additionalDetailsText\n Your format should not include any extra text, just Ingredients\nSteps\nServing Instructions"
            }
          ]
        }
      ]
    });

    try {
      final response = await http.post(url, headers: headers, body: body);
      print("Gemini raw response: ${response.body}");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        String llmOutput =
            data['candidates']?[0]?['content']?['parts']?[0]?['text'] ??
                "No output from Gemini";

        recipe = "NOTE: ENSURE FOOD IS SAFE TO EAT BEFORE CONSUMPTION\n$llmOutput";
      } else {
        recipe = "Error fetching data - try again later";
      }
    } catch (e) {
      recipe = "Error fetching data - try again later";
    }
    notifyListeners();
  }
  void setImage(File image) {
    currentImage = image;
    extractedText = "";
    notifyListeners();
  }
  void loadItems() async{
      final prefs = await SharedPreferences.getInstance();
      List<String> savedData = prefs.getStringList('fullGroceryList') ?? [];
      List<List<dynamic>> loadedItems = savedData.map((itemString) {
        final decoded = jsonDecode(itemString);
        return [
          decoded['name'],
          DateTime.parse(decoded['date']),
        ];
      }).toList();
      allItems = loadedItems;
      notifyListeners();
  }
  void reorderItems(int oldIndex, int newIndex) async{
    List<dynamic> i = allItems[oldIndex];
    allItems.removeAt(oldIndex);
    allItems.insert(newIndex, i);

    final prefs = await SharedPreferences.getInstance();
      List<String> serialized = allItems.map((item) {
        return jsonEncode({
          'name': item[0],
          'date': (item[1] as DateTime).toIso8601String(),
        });
      }).toList();
      await prefs.setStringList('fullGroceryList', serialized);
      notifyListeners();
  }
  void saveDeleted(int index) async {
    allItems.removeAt(index);
    final prefs = await SharedPreferences.getInstance();
      List<String> serialized = allItems.map((item) {
        return jsonEncode({
          'name': item[0],
          'date': (item[1] as DateTime).toIso8601String(),
        });
      }).toList();
      await prefs.setStringList('fullGroceryList', serialized);
      notifyListeners();
  }
  void saveItems() async {
    await Future.wait(items.map((item) => scheduleExpiryNotification(item[0], item[1])));
    final prefs = await SharedPreferences.getInstance();
      List<String> existingData = prefs.getStringList('fullGroceryList') ?? [];
      final List<String> serializedNewItems = items.map((item) {
        return jsonEncode({
          'name': item[0],
          'date': (item[1] as DateTime).toIso8601String(),
        });
      }).toList();
      existingData.addAll(serializedNewItems);
      await prefs.setStringList('fullGroceryList', existingData);
      loadItems();
      notifyListeners();
  }
  void setExtractedText(String text) {
    extractedText = text;
    notifyListeners();
  }
  void deleteItem(int index){
    items.removeAt(index);
    notifyListeners();
  }
  void updateItems(int index, List<dynamic> item){
    items[index] = item;
    notifyListeners();
  }
  void addItem(List<dynamic> item){
    items.insert(0,item);
    notifyListeners();
  }
  void setInitialItems(String input) {
    List<List<dynamic>> parsedData = [];
    for (String line in input.trim().split('\n')) {
      List<String> parts = line.split('-');
      if (parts.length < 2) continue;
      String name = parts[0].trim();
      String timePart = parts[1].trim();
      RegExp regex = RegExp(r'(\d+)\s+week');
      Match? match = regex.firstMatch(timePart);
      if (match != null) {
        int weeks = int.parse(match.group(1)!);
        DateTime expiry = DateTime.now().add(Duration(days: weeks * 7));
        parsedData.add([name, expiry]);
      }
    }
    items = parsedData; 
    notifyListeners();
  }
  Future<void> scheduleExpiryNotification(String itemName, DateTime expiryDate) async {
    initializeTimeZones();

    if (expiryDate.isBefore(DateTime.now())) {
      await flutterLocalNotificationsPlugin.show(
        itemName.hashCode,
        'Item Expired!',
        '$itemName has expired!',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'expiry_channel',
            'Expiry Notifications',
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
      );
      print("IMMEDIATE NOTIFICATION: $itemName already expired");
      return;
    }

    DateTime scheduledDate = expiryDate.subtract(const Duration(days: 1));
    if (scheduledDate.isBefore(DateTime.now())) {
      scheduledDate = DateTime.now().add(const Duration(seconds: 10));
    }

    final tzScheduledDate = tz.TZDateTime.from(scheduledDate, tz.local);

    await flutterLocalNotificationsPlugin.zonedSchedule(
      itemName.hashCode,
      'Item Expiring Soon',
      '$itemName expires tomorrow!',
      tzScheduledDate,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'expiry_channel',
          'Expiry Notifications',
          channelDescription: 'Notifies when an item is about to expire',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    );

    print("SCHEDULED: $itemName at $tzScheduledDate");
  }



  Future<void> pickImage(ImageSource source) async {
    final XFile? pickedFile = await _picker.pickImage(source: source);
    if (pickedFile != null) {
      setImage(File(pickedFile.path));
    }
  }

  Future<void> extractText() async {
    if (currentImage == null) return;

    final inputImage = InputImage.fromFile(currentImage!);
    final textRecognizer = TextRecognizer();
    final RecognizedText recognizedText =
        await textRecognizer.processImage(inputImage);

    String ocrText = recognizedText.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(', ');

    final url = Uri.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent");

    final headers = {
      "Content-Type": "application/json",
      "X-goog-api-key": "AIzaSyDSXOH8xyUtOzPi4A_RS-kq4smR6kk7dEs",
    };

    final body = jsonEncode({
      "contents": [
        {
          "parts": [
            {
              "text":
                  "For each product in the text below, extract generic item name without abbreviations, estimate the expiry date in strict relative exact weeks format as if purchased today. Return a plain list of generic product name - # weeks only, one per line, with no extra text, headings, or explanations:\n$ocrText"
            }
          ]
        }
      ]
    });

    try {
      final response = await http.post(url, headers: headers, body: body);
      print("Gemini raw response: ${response.body}");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        String llmOutput =
            data['candidates']?[0]?['content']?['parts']?[0]?['text'] ??
                "No output from Gemini";

        setExtractedText(llmOutput);
        setInitialItems(llmOutput);
      } else {
        setExtractedText("Error: ${response.body}");
      }
    } catch (e) {
      setExtractedText("Error: $e");
    }
  }
}
class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}
class _MyHomePageState extends State<MyHomePage> {
  var selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    Widget page;
    switch (selectedIndex) {
      case 0:
        page = const GeneratorPage();
        break;
      case 1:
        page = const InventoryPage();
        break;
      case 2:
        page = const RecipePage();
        break;
      default:
        page = const Center(child: Text("Page not implemented"));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("my virtual fridge", style:TextStyle(color: Color.fromARGB(255, 220, 193, 160), fontFamily: 'CustomFont2', fontSize: 33), ),
        backgroundColor: Color.fromARGB(255, 0, 0, 30),
        iconTheme: IconThemeData(color:Color.fromARGB(255, 220, 193, 160)),
      ),
      drawer: Drawer(
        backgroundColor: const Color.fromARGB(255, 220, 193, 160),
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(
                color: Color.fromARGB(255, 0,0,50),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'my virtual fridge',
                    style: TextStyle(
                      color: Color.fromARGB(255, 253, 226, 196),
                      fontSize: 33,
                      fontFamily: 'CustomFont2',
                      
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading:
                  const Icon(Icons.camera, color: Color.fromARGB(255, 0, 20, 70)),
              title: const Text(
                'stock pantry',
                style: TextStyle(color: Color.fromARGB(255, 0, 20, 70), fontFamily: 'CustomFonts', fontSize: 20),
              ),
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  selectedIndex = 0;
                });
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.kitchen, color: Color.fromARGB(255, 0,20,70)),
              title: const Text(
                'take inventory',
                style: TextStyle(color: Color.fromARGB(255, 0, 20, 70), fontFamily: 'CustomFonts', fontSize: 20),
              ),
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  selectedIndex = 1;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.bakery_dining,
                  color: Color.fromARGB(255, 0,20,70)),
              title: const Text(
                'Discover Recipes',
                style: TextStyle(color: Color.fromARGB(255, 0, 20, 70), fontFamily: 'CustomFonts', fontSize: 20)
              ),
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  selectedIndex = 2;
                });
              },
            ),
          ],
        ),
      ),
      body: page,
    );
  }
}

class GeneratorPage extends StatefulWidget {
  const GeneratorPage({super.key});

  @override
  State<GeneratorPage> createState() => _GeneratorPageState();
}

class _GeneratorPageState extends State<GeneratorPage> {
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();

    return Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage("assets/images/kitchenpage1.png"),
          fit: BoxFit.cover,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const SizedBox(height: 50),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(Icons.camera_alt_rounded, size: 100, color:Colors.blueGrey.shade100),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(0),
                            side: BorderSide(color: Colors.black38, width: 2),
                          ),
                          backgroundColor: Colors.black54,
                          title: const Text("Pick an Image", style: TextStyle(color:Colors.grey),),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Consumer<MyAppState>(
                                builder: (context, appState, _) {
                                  return appState.currentImage != null
                                      ? Image.file(appState.currentImage!, height: 200)
                                      : const Text("No image selected", style: TextStyle(color:Colors.grey));
                                },
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton(
                                style:ElevatedButton.styleFrom(backgroundColor: Colors.black54),
                                onPressed: () => appState.pickImage(ImageSource.gallery),
                                child: const Text("Pick from Gallery",style: TextStyle(color:Colors.grey)),
                              ),
                              const SizedBox(height: 10),
                              ElevatedButton(
                                style:ElevatedButton.styleFrom(backgroundColor: Colors.black54),
                                onPressed: () => appState.pickImage(ImageSource.camera),
                                child: const Text("Pick from Camera",style: TextStyle(color:Colors.grey)),
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton(
                                style:ElevatedButton.styleFrom(backgroundColor: Colors.black54),
                                onPressed: () async {
                                  await appState.extractText();
                                  if (!mounted) return;
                                  Navigator.of(context).pop();
                                  showDialog(
                                    context: context,
                                    builder: (context) {
                                      return AlertDialog(
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(0),
                                          side: BorderSide(color: Colors.black38, width: 2),
                                        ),
                                        backgroundColor: Colors.black54,
                                        title: const Text("Edit Items",style: TextStyle(color:Colors.grey)),
                                        content: SizedBox(
                                          height: 400,
                                          child: Column(
                                            children: [
                                              Expanded(
                                                child: SingleChildScrollView(
                                                  child: Consumer<MyAppState>(
                                                    builder: (context, appState, _) {
                                                      return Column(
                                                        children: appState.items
                                                            .asMap()
                                                            .entries
                                                            .map((entry) {
                                                          final index = entry.key;
                                                          final item = entry.value;
                                                          final selectedDate =
                                                              item[1] as DateTime;
                                                          return Padding(
                                                            padding: const EdgeInsets.symmetric(vertical: 4.0),
                                                            child: Row(
                                                              children: [
                                                                Expanded(
                                                                  child: TextField(
                                                                    style: TextStyle(
                                                                      color: Colors.grey,
                                                                      fontSize: 16,
                                                                    ),
                                                                    controller: TextEditingController(text: item[0]),
                                                                    decoration: const InputDecoration(
                                                                      border: OutlineInputBorder(),
                                                                      labelText: 'Item Name',
                                                                      labelStyle: TextStyle(color: Colors.grey),
                                                                      
                                                                      focusedBorder: OutlineInputBorder(
                                                                        borderSide: BorderSide(color: Colors.grey, width: 2),
                                                                      ),
                                                                      
                                                                    ),
                                                                    cursorColor: Colors.grey,
                                                                    onChanged: (newValue) {
                                                                      item[0] = newValue;
                                                                    },
                                                                    onEditingComplete: () {
                                                                      appState.updateItems(index, item);
                                                                      FocusScope.of(context).unfocus();
                                                                    },
                                                                  ),
                                                                ),
                                                                const SizedBox(width: 8),
                                                                TextButton.icon(
                                                                  icon: const Icon(Icons.calendar_today, color: Colors.grey),
                                                                  label: Text(
                                                                    "${selectedDate.year}-${selectedDate.month}-${selectedDate.day}", style: TextStyle(color: Colors.grey)
                                                                  ),
                                                                  onPressed: () async {
                                                                    DateTime? picked = await showDatePicker(
                                                                      context: context,
                                                                      initialDate: selectedDate,
                                                                      firstDate: DateTime(2000),
                                                                      lastDate: DateTime(2100),
                                                                    );
                                                                    if (picked != null) {
                                                                      item[1] = picked;
                                                                      appState.updateItems(index, item);
                                                                    }
                                                                  },
                                                                ),
                                                                IconButton(onPressed: () async {appState.deleteItem(index);}, icon: Icon(Icons.delete, color: Colors.grey))
                                                              ],
                                                            ),
                                                          );
                                                        }).toList(),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                onPressed: () {
                                                  appState.addItem(["Enter Item", DateTime.now()]);
                                                },
                                                icon: const Icon(Icons.add, color: Colors.grey),
                                              ),
                                            ],
                                          ),
                                        ),
                                        actions: [
                                          Row(
                                            children: [
                                              TextButton(
                                                child: const Text("Close", style: TextStyle(color: Colors.grey)),
                                                onPressed: () {
                                                  Navigator.of(context).pop();
                                                },
                                              ),
                                              TextButton(onPressed: (){
                                                appState.saveItems();
                                                Navigator.of(context).pop();
                                              }, child: const Text("Save", style: TextStyle(color: Colors.grey))),
                                            ],
                                          ),
                                      
                                        ],
                                      );
                                    },
                                  );
                                },
                                child: const Text("Extract Text",style: TextStyle(color:Colors.grey)),
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              child: const Text("Close", style: TextStyle(color:Colors.grey)),
                              onPressed: () {
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    appState.loadItems();

      return Container(
        decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage("assets/images/kitchenpage1.png"),
          fit: BoxFit.cover,
        ),
      ),
      child: Center(
        child: Column(
          children: [
            Expanded(
              child: SizedBox(
                width: double.infinity,
                child: ReorderableWrap(
                  spacing: 8,
                  runSpacing: 8,
                  padding: const EdgeInsets.all(8),
                  children: appState.allItems.map((item) {
                    return ElevatedButton(
                      onPressed: () {
                        print("pressed");
                      },
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: Colors.blueGrey.shade100,
                        fixedSize: const Size(80, 80),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              item[0].toString(),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              "${item[1].year}-${item[1].month}-${item[1].day}",
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 10),
                            )
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      appState.reorderItems(oldIndex, newIndex);
                    });
                  },
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DragTarget<int>(
                  builder: (context, candidateData, rejectedData) {
                    return Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Container(
                        width: 100,
                        height: 100,
                        child: Center(child: Icon(Icons.delete, color: candidateData.isNotEmpty ? const Color.fromARGB(255, 106, 30, 24): Color.fromARGB(255, 100,100,120), size: 100,)),
                      ),
                    );
                  },
                  onAcceptWithDetails: (details) {
                    appState.saveDeleted(details.data);
                  },
                ),
                const SizedBox(width: 16), 
              ],
            ),
          ],
        ),
        
      ),
    );
  }
}


class RecipePage extends StatefulWidget {
  const RecipePage({super.key});

  @override
  State<RecipePage> createState() => _RecipePage();
}

class _RecipePage extends State<RecipePage> {

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    appState.loadItems();

    return Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage("assets/images/kitchenpage1.png"),
          fit: BoxFit.cover,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            TextField(
              decoration: InputDecoration(
                labelText: 'Enter Extra Meal Details',
                border: OutlineInputBorder(),
                fillColor: Colors.blueGrey.shade200,
                filled: true,
              ),
              onSubmitted: (value) {
                appState.additionalDetailsText = value;
              },
            ),
           Padding(
             padding: const EdgeInsets.all(8.0),
             child: ElevatedButton(
                  
                  style:ElevatedButton.styleFrom(backgroundColor: Color.fromARGB(200,0,0,0), side: BorderSide(color: Color.fromARGB(255, 0,0,0),width: 2,),shape: RoundedRectangleBorder(borderRadius: BorderRadiusGeometry.circular(5)),),
                  onPressed: () => appState.generateRecipe(),
                  child: const Text("Check the Recipe Book...",style: TextStyle(color:Colors.grey)),
                ),
           ),
           
           Container(
            height:600,
            width:300,
            decoration: BoxDecoration(
                color:Color.fromARGB(200, 0, 0,0),
                border: Border.all(
                  color: Color.fromARGB(255,0,0,0),
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
            
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: SingleChildScrollView(
                  child: Text(
                    appState.recipe,
                    style: TextStyle(fontSize: 16, fontFamily: 'CustomFonts', color: Color.fromARGB(180, 220, 193, 160)),
                  ),
                ),
              ),
            ),
            
          ]
      )
      ),
    );
  }
}