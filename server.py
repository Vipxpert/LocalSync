from flask import Flask, render_template, request, send_from_directory, jsonify, g
import sqlite3
import os
import platform
import pathlib
import socket
import subprocess
from datetime import datetime
from urllib.parse import unquote



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
    file_name = os.path.basename(file.filename)  # Prevent path traversal
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

    # Reject zero-byte uploads
    file.seek(0, os.SEEK_END)
    size = file.tell()
    file.seek(0)
    if size == 0:
        print(f"[UPLOAD] Zero-byte file rejected: {file.filename}")
        return '[SERVER] Empty file not allowed. ', 400

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

################################################################################################################################################################################################################
#API for the clients




if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3000, debug=True)








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
