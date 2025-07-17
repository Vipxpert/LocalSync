from flask import Flask, render_template, request, send_from_directory, jsonify, g
import os
import platform
import pathlib
import socket
import subprocess
from datetime import datetime
from urllib.parse import unquote
from zeroconf import Zeroconf, ServiceBrowser, ServiceInfo, ServiceListener
import time
import json
import threading

discovered_services = []
zeroconf_instance = None
service_info = None

class MyListener(ServiceListener):
    def add_service(self, zeroconf, type, name):
        info = zeroconf.get_service_info(type, name)
        if info:
            service = {
                'name': name,
                'host': socket.inet_ntoa(info.addresses[0]),
                'port': info.port
            }
            # Avoid adding self
            current_ip = get_local_ip()
            if service['host'] != current_ip:
                discovered_services.append(service)

    def remove_service(self, zeroconf, type, name):
        global discovered_services
        discovered_services = [s for s in discovered_services if s['name'] != name]
    
    def update_service(self, zeroconf, type, name):
        pass

def get_local_ip():
    """Get the local IP address"""
    try:
        # Try different methods based on platform
        if platform.system() == 'Windows':
            # Windows method
            result = subprocess.run(['ipconfig'], capture_output=True, text=True)
            lines = result.stdout.split('\n')
            for line in lines:
                if 'IPv4 Address' in line or 'IPv4' in line:
                    ip = line.split(':')[-1].strip()
                    if ip and not ip.startswith('127.') and '.' in ip:
                        return ip
        else:
            # Unix/Android method
            try:
                result = subprocess.run(['ifconfig'], capture_output=True, text=True)
                lines = result.stdout.split('\n')
                wlan_section = False
                for line in lines:
                    if 'wlan0:' in line:
                        wlan_section = True
                        continue
                    if wlan_section and 'inet ' in line:
                        parts = line.split()
                        for part in parts:
                            if '.' in part and not part.startswith('127.'):
                                return part
                        wlan_section = False
            except:
                pass
        
        # Fallback method
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "127.0.0.1"

def get_device_info():
    """Get device name for service registration"""
    try:
        user = os.environ.get("USER") or os.environ.get("USERNAME") or platform.node()
        
        if platform.system() == 'Windows':
            try:
                output = subprocess.check_output(['wmic', 'computersystem', 'get', 'model'], text=True)
                lines = [line.strip() for line in output.splitlines() if line.strip()]
                model = lines[1] if len(lines) > 1 else "UnknownModel"
            except:
                model = "UnknownWindows"
        else:
            try:
                model = subprocess.check_output(['getprop', 'ro.product.model'], text=True).strip()
                if not model:
                    with open('/sys/devices/virtual/dmi/id/product_name', 'r') as f:
                        model = f.read().strip()
            except:
                model = "UnknownAndroid"
        
        return f"{model}_{user}".replace(" ", "_")
    except:
        return "LocalSync_Device"

def register_service():
    """Register this Flask server as a discoverable service"""
    global zeroconf_instance, service_info
    
    try:
        local_ip = get_local_ip()
        device_name = get_device_info()
        port = 3000
        
        # Create service info
        service_name = f"{device_name}._localsync._tcp.local."
        service_info = ServiceInfo(
            "_localsync._tcp.local.",
            service_name,
            addresses=[socket.inet_aton(local_ip)],
            port=port,
            properties={
                'device_name': device_name,
                'current_directory': str(pathlib.Path(__file__).parent.resolve()),
                'environment': 'windows' if platform.system() == 'Windows' else 'android'
            }
        )
        
        # Register service
        zeroconf_instance = Zeroconf()
        zeroconf_instance.register_service(service_info)
        
        # Start service browser for discovery
        browser = ServiceBrowser(zeroconf_instance, "_localsync._tcp.local.", MyListener())
        
        print(f"Service registered: {service_name} at {local_ip}:{port}")
        return True
    except Exception as e:
        print(f"Failed to register service: {e}")
        return False

def unregister_service():
    """Unregister the service"""
    global zeroconf_instance, service_info
    
    if zeroconf_instance and service_info:
        try:
            zeroconf_instance.unregister_service(service_info)
            zeroconf_instance.close()
            print("Service unregistered")
        except Exception as e:
            print(f"Error unregistering service: {e}")

# Start service registration in background
def start_discovery():
    register_service()

discovery_thread = threading.Thread(target=start_discovery, daemon=True)
discovery_thread.start()

app = Flask(__name__)

###############################################################################################################################################
#Web endpoints
@app.route('/')
@app.route('/happy_birthday')
def hello_world():
    # Define variables
    name = "Mẹ mều!"
    messages = ["Chúc mẹ nhiều may mắn và sức khoẻ!", "Have a great day!", "Party time!"]
    return render_template('HTML/happy_birthday/happy-birthday.html', name=name, messages=messages)

###############################################################################################################################################
#API for the servers file transfering

if platform.system() == 'Windows':
    CURRENT_DIRECTORY = pathlib.Path(__file__).parent.resolve()
else:
    CURRENT_DIRECTORY = pathlib.Path(__file__).parent.resolve()


PC_GEOMETRY_DASH_FOLDER = r'C:\Users\Vipxpert\AppData\Local\GeometryDash'
MOBILE_GEOMETRY_DASH_FOLDER = '/storage/self/primary/Android/media/com.geode.launcher/save'
MOBILE_GEOMETRY_DASH_FOLDER_ALT = '/storage/emulated/0/Android/media/com.geode.launcher/save'

# Allow access to these specific files
EXCEPTION_PATHS = {
    'CCGameManager.dat': pathlib.Path(os.path.join(PC_GEOMETRY_DASH_FOLDER, 'CCGameManager.dat')).resolve(),
    'CCGameManager2.dat': pathlib.Path(os.path.join(PC_GEOMETRY_DASH_FOLDER, 'CCGameManager2.dat')).resolve(),
    'CCLocalLevels.dat': pathlib.Path(os.path.join(PC_GEOMETRY_DASH_FOLDER, 'CCLocalLevels.dat')).resolve(),
    'CCLocalLevels2.dat': pathlib.Path(os.path.join(PC_GEOMETRY_DASH_FOLDER, 'CCLocalLevels2.dat')).resolve(),
    'CCGameManager.dat': pathlib.Path(os.path.join(MOBILE_GEOMETRY_DASH_FOLDER, 'CCGameManager.dat')).resolve(),
    'CCGameManager2.dat': pathlib.Path(os.path.join(MOBILE_GEOMETRY_DASH_FOLDER, 'CCGameManager2.dat')).resolve(),
    'CCLocalLevels.dat': pathlib.Path(os.path.join(MOBILE_GEOMETRY_DASH_FOLDER, 'CCLocalLevels.dat')).resolve(),
    'CCLocalLevels2.dat': pathlib.Path(os.path.join(MOBILE_GEOMETRY_DASH_FOLDER, 'CCLocalLevels2.dat')).resolve(),
    'CCGameManager.dat': pathlib.Path(os.path.join(MOBILE_GEOMETRY_DASH_FOLDER_ALT, 'CCGameManager.dat')).resolve(),
    'CCGameManager2.dat': pathlib.Path(os.path.join(MOBILE_GEOMETRY_DASH_FOLDER_ALT, 'CCGameManager2.dat')).resolve(),
    'CCLocalLevels.dat': pathlib.Path(os.path.join(MOBILE_GEOMETRY_DASH_FOLDER_ALT, 'CCLocalLevels.dat')).resolve(),
    'CCLocalLevels2.dat': pathlib.Path(os.path.join(MOBILE_GEOMETRY_DASH_FOLDER_ALT, 'CCLocalLevels2.dat')).resolve()
}

# Add any folders you want to allow *all files inside*
EXCEPTION_FOLDERS = {
    pathlib.Path(PC_GEOMETRY_DASH_FOLDER).resolve(),
    pathlib.Path(MOBILE_GEOMETRY_DASH_FOLDER).resolve(),
    pathlib.Path(MOBILE_GEOMETRY_DASH_FOLDER_ALT).resolve(),
    pathlib.Path(os.path.join(CURRENT_DIRECTORY, 'host')).resolve(),
    pathlib.Path(PC_GEOMETRY_DASH_FOLDER).resolve(),
    pathlib.Path(MOBILE_GEOMETRY_DASH_FOLDER).resolve(),
    pathlib.Path(MOBILE_GEOMETRY_DASH_FOLDER_ALT).resolve()
}


def is_safe_path(base_path, custom_path, filename=None):
    try:
        base_path = pathlib.Path(base_path).resolve()

        if not custom_path:
            base_path.mkdir(parents=True, exist_ok=True)
            return base_path

        custom_path = pathlib.Path(custom_path).resolve()

        # Allow subfolders of base_path
        if base_path in custom_path.parents or custom_path == base_path:
            custom_path.mkdir(parents=True, exist_ok=True)
            return custom_path
        
        # Allow if full custom path is in folder exception list
        for folder in EXCEPTION_FOLDERS:
            if folder == custom_path or folder in custom_path.parents:
                custom_path.mkdir(parents=True, exist_ok=True)
                return custom_path

        # Allow explicitly whitelisted file paths
        if filename and filename in EXCEPTION_PATHS:
            exception_file = EXCEPTION_PATHS[filename]
            if custom_path == exception_file.parent:
                custom_path.mkdir(parents=True, exist_ok=True)
                return custom_path

        # Default fallback: restrict to base_path only
        base_path.mkdir(parents=True, exist_ok=True)
        print("Path is not safe! Using the default directory.")
        return base_path

    except Exception:
        base_path.mkdir(parents=True, exist_ok=True)
        print("Path is not safe! Using the default directory.")
        return base_path


def parse_time(timestr):
    """
    Parses ISO8601 or timestamp string to datetime.
    Returns None if parsing fails.
    """
    if not timestr:
        return None
    try:
        # Example accepted format: 2025-05-22T15:30:00 or just timestamp seconds
        try:
            return datetime.fromisoformat(timestr)
        except ValueError:
            # fallback try int timestamp
            ts = int(timestr)
            return datetime.fromtimestamp(ts)
    except Exception:
        return None

@app.route('/files/mtime', methods=['GET'])
def get_file_mtime():
    custom_path = request.args.get('custom_path', '')
    filename = request.args.get('filename', '')
    if not filename:
        return '[SERVER] Filename is required. ', 400

    safe_path = is_safe_path(CURRENT_DIRECTORY, custom_path, filename)
    full_path = os.path.join(safe_path, filename)

    if not os.path.exists(full_path):
        return '[SERVER] File not found. ', 404

    mtime = os.path.getmtime(full_path)
    return str(mtime), 200

@app.route('/upload/single', methods=['POST'])
def upload_single():
    if 'file' not in request.files:
        return '[SERVER] No file part. ', 400

    file = request.files['file']
    if file.filename == '':
        return '[SERVER] No selected file. ', 400

    # Sanitize and decode the custom_path
    custom_path = request.args.get('custom_path') or ''
    file_name = os.path.basename(file.filename or '')  # Prevent path traversal
    safe_path = is_safe_path(CURRENT_DIRECTORY, custom_path, file_name)
    save_path = os.path.join(safe_path, file_name)

    # Parse time parameter (prefer form, fallback to query)
    time_str = request.form.get('time') or request.args.get('time')
    upload_time = parse_time(time_str)

    # Check timestamp before reading file
    if os.path.exists(save_path) and upload_time:
        existing_mtime = datetime.fromtimestamp(os.path.getmtime(save_path))
        if upload_time <= existing_mtime:
            print(f"[UPLOAD] Skipped replacing {file_name} because existing file is newer or same.")
            return '[SERVER] Existing file is newer or same, upload skipped. ', 200

    # Save file safely
    os.makedirs(safe_path, exist_ok=True)
    file.save(save_path)
    print(f"[UPLOAD] File received: {file_name}")
    print(f"[UPLOAD] Requested path: {custom_path}")
    print(f"[UPLOAD] File saved to: {save_path}")

    if upload_time:
        mod_time = upload_time.timestamp()
        os.utime(save_path, (mod_time, mod_time))

    return '[SERVER] File uploaded successfully. ', 200

@app.route('/files/<filename>', methods=['GET'])
def download_file(filename):
    custom_path = request.args.get('custom_path', '')
    safe_path = is_safe_path(CURRENT_DIRECTORY, custom_path, filename)
    full_path = os.path.join(safe_path, filename)

    if not os.path.exists(full_path):
        print(f"[DOWNLOAD] File not found: {full_path}")
        return '[SERVER] File not found. ', 404

    if os.path.getsize(full_path) == 0:
        print(f"[DOWNLOAD] Zero-byte file not sent: {filename}")
        return '[SERVER] File is empty. ', 404

    # Time check before reading file
    time_str = request.args.get('time')
    client_time = parse_time(time_str)
    if client_time:
        server_mtime = datetime.fromtimestamp(os.path.getmtime(full_path))
        if server_mtime <= client_time:
            print(f"[DOWNLOAD] File {filename} not sent because client has newer or same file.")
            return '[SERVER] No update needed. ', 204

    # Read and validate file content (binary-safe)
    try:
        with open(full_path, 'rb') as f:
            content_bytes = f.read()
            try:
                content_str = content_bytes.decode('utf-8').strip().lower()

                exact_errors = {
                    "file not found",
                    "error",
                    "not found",
                    "404 error"
                }

                html_404_snippet = (
                    "<!doctype html>"
                    "<html lang=en>"
                    "<title>404 not found</title>"
                    "<h1>not found</h1>"
                    "<p>the requested url was not found on the server. "
                    "if you entered the url manually please check your spelling and try again.</p>"
                )

                if content_str in exact_errors:
                    print(f"[DOWNLOAD] File {filename} has only error content: '{content_str}'")
                    return '[SERVER] Invalid file content. ', 404

                normalized_str = content_str.replace(' ', '').replace('\r', '')
                if html_404_snippet in normalized_str:
                    print(f"[DOWNLOAD] File {filename} contains 404 HTML error page")
                    return '[SERVER] Invalid file content. ', 404

            except UnicodeDecodeError:
                # Binary file — skip text validation
                pass

    except Exception as e:
        print(f"[DOWNLOAD] Error reading file {filename}: {e}")
        return '[SERVER] Unable to read file. ', 500

    print(f"[DOWNLOAD] File requested: {filename}")
    print(f"[DOWNLOAD] Requested path: {custom_path}")
    print(f"[DOWNLOAD] File served from: {full_path}")
    return send_from_directory(safe_path, filename)


@app.route('/get_directory', methods=['GET'])
def get_directory():
    current_directory = os.getcwd().rstrip(os.sep)
    return jsonify({'directory': current_directory})

@app.route('/get_device_name', methods=['GET'])
def get_device_name():
    try:
        user = os.environ.get("USER") or os.environ.get("USERNAME") or platform.node()

        if platform.system() == 'Windows':
            # Windows: Use wmic to get the model
            try:
                output = subprocess.check_output(['wmic', 'computersystem', 'get', 'model'], text=True)
                lines = [line.strip() for line in output.splitlines() if line.strip()]
                # lines[0] = 'Model', lines[1] = actual model
                model = lines[1] if len(lines) > 1 else "UnknownModel"
            except Exception as e:
                print(f"Failed to detect model: {e}")
                model = "UnknownWindows"
        else:
            # On Android / Termux
            try:
                model = subprocess.check_output(['getprop', 'ro.product.model'], text=True).strip()
                if not model:
                    # Fallback for Linux PC
                    with open('/sys/devices/virtual/dmi/id/product_name', 'r') as f:
                        model = f.read().strip()
            except Exception as e:
                print(f"Failed to detect model: {e}")
                model = "UnknownAndroid"

        # Combine: model (user)
        final_name = f"{model} ({user})"

    except Exception as e:
        final_name = f"Unknown ({str(e)})"

    return jsonify({"name": final_name})

@app.route('/api/environment', methods=['GET'])
def get_environment():
    # Check if running in Termux
    termux_bash = "/data/data/com.termux/files/usr/bin/bash"
    
    if platform.system() == "Windows":
        environment = "windows"
    else:
        environment = "android"
    
    return jsonify({
        "status": "success",
        "environment": environment
    })

@app.route('/api/discover_services', methods=['GET'])
def discover_services():
    """Return discovered LocalSync services"""
    global discovered_services
    return jsonify({
        "status": "success",
        "services": discovered_services
    })

@app.route('/api/scan_network', methods=['GET'])
def scan_network():
    """Scan network for LocalSync services"""
    try:
        # Get current network range
        local_ip = get_local_ip()
        if local_ip == "127.0.0.1":
            return jsonify({"status": "error", "message": "Cannot determine network range"})
        
        # Extract network base (e.g., 192.168.1.x)
        ip_parts = local_ip.split('.')
        if len(ip_parts) != 4:
            return jsonify({"status": "error", "message": "Invalid IP format"})
        
        network_base = '.'.join(ip_parts[:3])
        found_services = []
        
        # Scan common IP range (1-254)
        import concurrent.futures
        
        def check_ip(ip):
            try:
                response = subprocess.run(
                    ['curl', '-s', '--connect-timeout', '2', f'http://{ip}:3000/api/environment'],
                    capture_output=True, text=True, timeout=3
                )
                if response.returncode == 0:
                    try:
                        data = json.loads(response.stdout)
                        if data.get('status') == 'success':
                            # Get device name
                            name_response = subprocess.run(
                                ['curl', '-s', '--connect-timeout', '2', f'http://{ip}:3000/get_device_name'],
                                capture_output=True, text=True, timeout=3
                            )
                            device_name = "Unknown Device"
                            if name_response.returncode == 0:
                                try:
                                    name_data = json.loads(name_response.stdout)
                                    device_name = name_data.get('name', 'Unknown Device')
                                except:
                                    pass
                            
                            return {
                                'ip': ip,
                                'name': device_name,
                                'environment': data.get('environment', 'unknown'),
                                'port': 3000
                            }
                    except json.JSONDecodeError:
                        pass
            except:
                pass
            return None
        
        # Scan in parallel for faster results
        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as executor:
            futures = []
            for i in range(1, 255):
                ip = f"{network_base}.{i}"
                if ip != local_ip:  # Skip self
                    futures.append(executor.submit(check_ip, ip))
            
            for future in concurrent.futures.as_completed(futures, timeout=30):
                result = future.result()
                if result:
                    found_services.append(result)
        
        return jsonify({
            "status": "success",
            "found_services": found_services,
            "scan_range": f"{network_base}.1-254"
        })
        
    except Exception as e:
        return jsonify({
            "status": "error",
            "message": str(e)
        })

@app.route('/api/check_device_status', methods=['POST'])
def check_device_status():
    """Check status of devices provided in request"""
    try:
        data = request.get_json()
        if not data or 'devices' not in data:
            return jsonify({"status": "error", "message": "No devices provided"})
        
        devices = data['devices']
        results = []
        
        for device in devices:
            ip = device.get('ip')
            if not ip:
                continue
                
            try:
                # Check if device is online
                response = subprocess.run(
                    ['curl', '-s', '--connect-timeout', '2', f'http://{ip}:3000/api/environment'],
                    capture_output=True, text=True, timeout=3
                )
                
                if response.returncode == 0:
                    try:
                        env_data = json.loads(response.stdout)
                        if env_data.get('status') == 'success':
                            # Get device info
                            name_response = subprocess.run(
                                ['curl', '-s', '--connect-timeout', '2', f'http://{ip}:3000/get_device_name'],
                                capture_output=True, text=True, timeout=3
                            )
                            device_name = device.get('name', 'Unknown')
                            if name_response.returncode == 0:
                                try:
                                    name_data = json.loads(name_response.stdout)
                                    device_name = name_data.get('name', device_name)
                                except:
                                    pass
                            
                            # Get directory info
                            dir_response = subprocess.run(
                                ['curl', '-s', '--connect-timeout', '2', f'http://{ip}:3000/get_directory'],
                                capture_output=True, text=True, timeout=3
                            )
                            current_dir = ""
                            if dir_response.returncode == 0:
                                try:
                                    dir_data = json.loads(dir_response.stdout)
                                    current_dir = dir_data.get('directory', '')
                                except:
                                    pass
                            
                            results.append({
                                'ip': ip,
                                'name': device_name,
                                'environment': env_data.get('environment', 'unknown'),
                                'current_directory': current_dir,
                                'status': 'online',
                                'last_seen': datetime.now().isoformat()
                            })
                        else:
                            results.append({
                                'ip': ip,
                                'name': device.get('name', 'Unknown'),
                                'status': 'offline',
                                'last_seen': device.get('last_seen', '')
                            })
                    except json.JSONDecodeError:
                        results.append({
                            'ip': ip,
                            'name': device.get('name', 'Unknown'),
                            'status': 'offline',
                            'last_seen': device.get('last_seen', '')
                        })
                else:
                    results.append({
                        'ip': ip,
                        'name': device.get('name', 'Unknown'),
                        'status': 'offline',
                        'last_seen': device.get('last_seen', '')
                    })
                    
            except Exception as e:
                results.append({
                    'ip': ip,
                    'name': device.get('name', 'Unknown'),
                    'status': 'error',
                    'error': str(e),
                    'last_seen': device.get('last_seen', '')
                })
        
        return jsonify({
            "status": "success",
            "devices": results
        })
        
    except Exception as e:
        return jsonify({
            "status": "error",
            "message": str(e)
        })

################################################################################################################################################################################################################
#API for the clients




if __name__ == '__main__':
    import atexit
    atexit.register(unregister_service)
    
    try:
        app.run(host='0.0.0.0', port=3000, debug=True)
    except KeyboardInterrupt:
        print("\nShutting down...")
        unregister_service()
    except Exception as e:
        print(f"Server error: {e}")
        unregister_service()








# silly example

# @app.route('/')
# @app.route('/happy_birthday')
# def hello_world():
#     # Define variables
#     name = "Alice"
#     messages = ["Wishing you joy!", "Have a great day!", "Party time!"]
#     # Build HTML with variables and list
#     messages_html = ''.join(f'<li>{msg}</li>' for msg in messages)
#     html_content = f'''
#     <!DOCTYPE html>
#     <html lang="en">
#     <head>
#         <meta charset="UTF-8" />
#         <meta name="viewport" content="width=device-width, initial-scale=1.0" />
#         <title>Happy Birthday Animation</title>
#         <link rel="stylesheet" type="text/css" href="/static/CSS/style.css" />
#     </head>
#     <body>
#         <h1 class="rainbow-text">Happy Birthday, {name}!</h1>
#         <button onclick="celebrate()">Yay</button>
#         <img src="/static/images/cate.jpg" alt="Cute Cat" class="cat-image" />
#         <ul>
#             {messages_html}
#         </ul>
#         <script>
#             function celebrate() {{
#                 const text = document.querySelector(".rainbow-text");
#                 text.classList.add("rotate");
#                 const catImage = document.querySelector(".cat-image");
#                 catImage.style.display = "block";
#             }}
#         </script>
#     </body>
#     </html>
#     '''
#     return html_content





#                 catImage.style.display = "block";
#             }}
#         </script>
#     </body>
#     </html>
#     '''
#     return html_content
