extends Control


# 🚫 违禁品名单 (Native API)
# 正常的 C# Mod 绝不需要直接调用这些 Windows 底层函数
# 如果出现了，说明它想绕过游戏引擎干坏事（读写内存、注入病毒、执行CMD）
var forbidden_imports = {
	"KERNEL32.dll": 50,  # 操作内存/进程的核心库
	"USER32.dll": 30,    # 监控键盘/鼠标
	"SHELL32.dll": 80,   # 执行系统命令 (cmd/powershell)
	"ADVAPI32.dll": 60,  # 修改注册表
	"VirtualProtect": 100, # 修改内存权限 (典型的病毒注入行为)
	"WriteProcessMemory": 100, # 修改游戏内存 (外挂/病毒特征)
	"GetProcAddress": 80, # 动态获取函数地址 (躲避静态查杀的常用手段)
	"InternetOpen": 60   # 底层联网 (非Unity联网)
}

# ================= 配置区域 =================

# 1. 威胁评分规则 (正则 : 分数)
# 分数越高越危险。
# 正则说明：(?!schemas) 是为了防止 xml 文件头里的 http 误报
var risk_rules = {
	# 🔴 毁灭级 (只要出现直接红名)
	"cmd\\.exe": 100,
	"powershell": 100,
	"os\\.remove": 100,
	"formatting C:": 100,
	"WebClient\\.Upload": 100, # 上传文件
	
	# 🟡 可疑级 (单个出现可能是误报，多了就危险)
	"http://(?!schemas)": 25, # 排除掉 schemas.microsoft.com
	"UnityWebRequest": 25,     # Unity 联网
	"Socket": 25,              # 底层网络套接字
	"System\\.IO\\.File\\.Delete": 30, # 删除文件
	"System\\.IO\\.Directory\\.Delete": 30,
	
	# 🟢 噪音级 (正常程序也常用，分很低，除非成堆出现否则忽略)
	"System\\.Diagnostics": 5, 
	"LoadLibrary": 10,
	"get_IP": 10,
	"WriteAllText": 5,
	
	# === 🆕 新增：逻辑炸弹防御 (针对 Scav 1.8.0 这类) ===
	
	# 1. 强制退出游戏 (Mod 绝不该拥有这个权限)
	"Application\\.Quit": 100,      # Unity 退出函数
	"Environment\\.Exit": 100,      # C# 系统退出函数
	"Process\\.Kill": 100,          # 杀进程
	"ForceCrash": 100,              # 某些游戏自带的崩溃测试函数
	
	# 2. 隐私窥探 (查户口)
	"GetSteamID": 50,               # 获取 Steam ID (通常是为了比对黑名单)
	"steamID": 20,                  # 变量名提及 (需警惕)
	"m_SteamID": 20,
	
	# 3. 针对性封禁词汇 (作者可能直球写代码)
	"Blacklist": 50,                # 黑名单
	"BanList": 50,                  # 封禁列表
	"IsBanned": 50,                 # "是否被封禁"

}

# 2. 白名单指纹库 (文件名 : [合法的MD5列表])
# 如果你的扫描器以后报错了正版文件，先用 get_md5() 获取它的哈希，填入这里
var safe_file_hashes = {
	"0Harmony.dll": [
		"2afc09f2cd4cba05d85cc7c4f7d62edb", 
		"如果有多个版本可以填第二行" 
	],
	"BepInEx.dll": [
		"这里填入正版BepInEx的MD5"
	],
}


# 🚫 黑名单指纹库 (已知的病毒文件 MD5)
# 只要碰到这个指纹，不管叫什么名字，直接报毒
var dangerous_file_hashes = [
	# 这里填入 RandomNpc.dll 的 MD5 (你可以用扫描器打印出来获取)
	"这里填入你扫描出的RandomNpc的MD5值" ,
	""
]

# 3. 忽略的大文件阈值 (字节)
const MAX_FILE_SIZE = 50 * 1024 * 1024 # 50MB

# ===========================================

@onready var status_label = $StatusLabel
@onready var result_container = $ResultList/VBoxContainer
@onready var mascot = $Mascot

# 缓存编译好的正则对象
var compiled_rules = {}

# === 1. 初始化界面 (版本号 + 免责声明) ===
func _ready():
	# A. 设置窗口标题和版本号
	DisplayServer.window_set_title("Duckov Security Scanner v1.0.1 (Beta)")
	
	# B. 动态添加免责声明 (在窗口底部生成一行小字)
	var disclaimer = Label.new()
	disclaimer.text = "免责声明: 本工具基于社区已知特征开发，不能保证 100% 拦截未知病毒。删除文件前请务必备份。"
	disclaimer.add_theme_font_size_override("font_size", 12) # 字体设小一点
	disclaimer.modulate = Color(1, 1, 1, 0.5) # 半透明，不抢眼
	
	# 把它放到屏幕底部居中
	disclaimer.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	disclaimer.position.y -= 10 # 往上提一点点
	add_child(disclaimer)

	# C. 原有的初始化逻辑
	get_tree().get_root().files_dropped.connect(_on_files_dropped)
	
	# 预编译正则
	for pattern in risk_rules:
		var regex = RegEx.new()
		regex.compile(pattern)
		compiled_rules[pattern] = regex
		
	status_label.text = "安全终端就绪。请拖入 Mod 文件夹..."
	status_label.modulate = Color.WHITE

func _on_files_dropped(files):
	var folder_path = files[0]
	var dir = DirAccess.open(folder_path)
	if dir:
		start_scan(folder_path)
	else:
		status_label.text = "错误：请拖入一个有效的文件夹！"
		status_label.modulate = Color.RED

func start_scan(path):
	# === 初始化 UI ===
	for child in result_container.get_children():
		child.queue_free()
	
	status_label.text = "正在初始化扫描引擎..."
	status_label.modulate = Color.YELLOW
	await get_tree().create_timer(0.3).timeout # 稍微停顿，增加仪式感
	
	# === 获取所有文件 ===
	var all_files = get_all_files(path)
	if all_files.size() == 0:
		status_label.text = "文件夹为空或无法读取！"
		return

	# === 开始循环扫描 ===
	var issues_found = 0
	var scanned_count = 0
	
	for file_path in all_files:
		# === 🆕 插入点：优先检查 info.ini ===
		if file_path.get_file() == "info.ini":
			var is_banned = check_info_ini(file_path)
			if is_banned:
				issues_found += 1
				print("🔴 发现封禁 ID: " + file_path)
				continue # 如果确定是坏的，这个文件就不用往下扫了
		# ===================================
		scanned_count += 1
		
		# 每扫描5个文件刷新一次界面，防止卡死
		if scanned_count % 5 == 0:
			status_label.text = "正在分析 (%d/%d): %s" % [scanned_count, all_files.size(), file_path.get_file()]
			await get_tree().process_frame
		
		# --- 核心扫描逻辑 ---
		var result = scan_single_file(file_path)
		var score = result["score"]
		
		# --- 结果判定 (红绿灯机制) ---
		if score >= 50:
			# 🔴 红色高危
			issues_found += 1
			add_alert_card(file_path.get_file(), result["details"], Color.RED, score)
			print("🔴 高危发现: " + file_path.get_file())
			
		elif score >= 20:
			# 🟡 黄色可疑
			issues_found += 1
			add_alert_card(file_path.get_file(), result["details"], Color.ORANGE, score)
			print("🟡 可疑文件: " + file_path.get_file())
			
		else:
			# 🟢 绿色/灰色 (分数很低，忽略)
			# print("🟢 安全/噪音: " + file_path.get_file() + " 分数: " + str(score))
			pass

	# === 最终结算 ===
	if issues_found == 0:
		status_label.text = "扫描完成：所有文件安全！(✅)"
		status_label.modulate = Color.GREEN
		# mascot.texture = load("res://happy_duck.png") # 如果你有图片的话
	else:
		status_label.text = "警告：发现 %d 个潜在威胁！请检查列表。" % issues_found
		status_label.modulate = Color.RED
		# mascot.texture = load("res://angry_duck.png")

# --- 辅助功能：递归获取文件 ---
func get_all_files(path: String) -> Array:
	var files = []
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir():
				if file_name != "." and file_name != "..":
					files.append_array(get_all_files(path + "/" + file_name))
			else:
				files.append(path + "/" + file_name)
			file_name = dir.get_next()
	return files

# --- 核心功能：清洗二进制乱码 ---
func extract_readable_text(raw_bytes: PackedByteArray) -> String:
	var safe_bytes = PackedByteArray()
	for b in raw_bytes:
		# 只保留 ASCII 可打印字符 (32-126) 以及 换行符
		if (b >= 32 and b <= 126) or b == 10 or b == 13:
			safe_bytes.append(b)
	return safe_bytes.get_string_from_ascii()

func scan_single_file(path: String) -> Dictionary:
	var file_obj = FileAccess.open(path, FileAccess.READ)
	if not file_obj: return {"score": 0, "details": []}
	
	var file_len = file_obj.get_length()
	if file_len == 0: return {"score": 0, "details": []}
	if file_len > MAX_FILE_SIZE: return {"score": 0, "details": []} # 跳过超大文件
	
	var file_name = path.get_file()
	var current_score = 0
	var found_details = []
	
	# === 1. 读取并清洗内容 ===
	var content_bytes = file_obj.get_buffer(file_len)
	var content_cleaned = extract_readable_text(content_bytes)
	var is_dll = path.get_extension().to_lower() == "dll"
	
	# === 2. DLL 深度结构检查 (仅针对 DLL) ===
	if is_dll:
		# --- A. 身份验证 (.NET 签名) ---
		var has_dotnet_magic = "BSJB" in content_cleaned
		
		# --- B. 伪装检测 (C++ 原生病毒) ---
		if not has_dotnet_magic:
			# 绝大多数 Unity Mod 必须是 C# (带BSJB)。
			# 如果是 DLL 但没有 BSJB，极大概率是伪装成 Mod 的原生病毒 (Scav 1.5 特征)
			current_score += 100
			found_details.append("🛑 伪装文件: 缺失 .NET 签名 (BSJB)")
			found_details.append("   └─ 解析: 这是一个原生二进制文件(C++/Native)，而不是正常的 Mod。")
		
		else:
			# --- C. 混淆/加壳检测 (信息密度) ---
			# 检查是否包含 Unity/Mod 开发的常用库
			var valid_markers = ["UnityEngine", "Assembly-CSharp", "BepInEx", "0Harmony", "System.Runtime", "mscorlib", "System"]
			var looks_like_unity_mod = false
			for marker in valid_markers:
				if marker in content_cleaned:
					looks_like_unity_mod = true
					break
			
			# 计算可读文本占比
			var readability_ratio = float(content_cleaned.length()) / float(file_len)
			
			# 如果既没引用 Unity 库，可读性又极低 (<1.5%)，说明被强力混淆或加密了
			if not looks_like_unity_mod and readability_ratio < 0.015:
				current_score += 80
				found_details.append("🛑 高度混淆/加密检测")
				found_details.append("   └─ 证据: 文件可读信息密度极低 (%.2f%%)，疑似加壳木马" % (readability_ratio * 100))

			# --- D. 🛡️ 违禁品搜身 (含 Harmony 豁免权) ---
			# 1. 判断是否为真正的 Harmony 库 (防止改名伪装)
			# 条件：文件名含 harmony 且 内容里确实有 Harmony 字符串
			var is_real_harmony = "harmony" in file_name.to_lower() and ("Harmony" in content_cleaned or "0Harmony" in content_cleaned)
			
			for bad_api in forbidden_imports:
				if bad_api in content_cleaned:
					# [豁免逻辑] 如果是真 Harmony，允许它调用内存操作函数 (因为它是补丁库)
					if is_real_harmony and bad_api in ["VirtualProtect", "GetProcAddress", "KERNEL32.dll", "LoadLibrary"]:
						# print("DEBUG: 已豁免 Harmony 的底层操作: ", bad_api)
						continue
					
					# 否则，一律严查
					current_score += forbidden_imports[bad_api]
					found_details.append("☢️ 违禁品检测: 发现底层系统调用 (%s)" % bad_api)
					
					# 如果伪装成普通 Mod 却调内核，罪加一等
					if looks_like_unity_mod and not is_real_harmony:
						current_score += 50
						found_details.append("   └─ 伪装警报: 该文件伪装成 Unity Mod，却在调用系统内核！")

	# === 3. 行为逻辑特征扫描 (正则检测) ===
	# 这一步针对所有文件，且 Harmony 没有豁免权 (Harmony 也不该写 Application.Quit)
	for pattern in compiled_rules:
		var regex = compiled_rules[pattern]
		# 搜索匹配项
		var match = regex.search(content_cleaned)
		if match:
			var weight = risk_rules[pattern]
			current_score += weight
			
			# 格式化显示名称 (去掉正则转义符)
			var display_name = pattern.replace("\\", "")
			found_details.append("⚡ 发现敏感行为: %s (+%d)" % [display_name, weight])
			
			# 如果是高危的逻辑炸弹，给出详细警告
			if weight >= 50:
				if "Quit" in display_name or "Exit" in display_name:
					found_details.append("   └─ 警告: 检测到强制退出游戏代码 (逻辑炸弹特征)")
				elif "SteamID" in display_name:
					found_details.append("   └─ 警告: 检测到针对 SteamID 的隐私读取行为")

	return {
		"score": current_score,
		"details": found_details
	}

# --- UI功能：生成警告卡片 ---
func add_alert_card(filename, details, color, score):
	var card = Label.new()
	# 组装提示文字
	var text = "⚠️ %s [危险指数: %d]\n" % [filename, score]
	for d in details:
		text += "   └─ 发现: %s\n" % d
		
	card.text = text
	card.modulate = color
	result_container.add_child(card)
	# 加个分隔线
	var separator = HSeparator.new()
	result_container.add_child(separator)

# === 3. 特攻检测：扫描 info.ini ===
func check_info_ini(path: String) -> bool:
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return false
	
	var content = f.get_as_text()
	# 官方实锤封禁的恶意 Mod ID
	if "3600714295" in content:
		add_alert_card("info.ini", [
			"🛑 官方封禁追杀令",
			"   └─ 检测到 Mod ID: 3600714295",
			"   └─ 结论: 这就是那个会导致闪退的恶意 Scav Mod，请立即删除！"
		], Color.RED, 9999) # 分数给极高，置顶显示
		return true # 发现问题
	return false
