extends PanelContainer

# ==========================================
# 📄 FileResultCard.gd (v1.9.1 Final)
# ==========================================

# 📡 信号：请求主程序弹出右键菜单
signal request_context_menu(global_pos, report_data)

@onready var status_icon = $VBoxContainer/HeaderBox/StatusIcon
@onready var summary_label = $VBoxContainer/HeaderBox/SummaryLabel
@onready var toggle_btn = $VBoxContainer/HeaderBox/ToggleButton
@onready var details_box = $VBoxContainer/DetailsBox

enum RiskLevel { INFO, WARNING, DANGER, CRITICAL }

var current_report = {} 

func _ready():
	toggle_btn.toggled.connect(_on_toggle)
	details_box.visible = false 
	details_box.fit_content = true 
	
	# 🖱️ 监听鼠标输入
	gui_input.connect(_on_gui_input)

func _on_toggle(pressed):
	details_box.visible = pressed
	toggle_btn.text = "收起详情 ▲" if pressed else "展开详情 ▼"

# 🖱️ 处理右键点击
func _on_gui_input(event):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			# 发送全局鼠标位置给主程序，用于弹出菜单
			emit_signal("request_context_menu", get_global_mouse_position(), current_report)

func setup(report: Dictionary):
	current_report = report 
	
	# === 🟢 如果在白名单中，直接渲染信任状态 ===
	if report.get("is_whitelisted", false):
		render_whitelisted_state(report)
		return

	# 1. 计算最高风险等级 (幽灵引用不参与)
	var max_risk = RiskLevel.INFO
	for cat in report["permissions"]:
		for item in report["permissions"][cat]:
			if not item.get("is_ghost", false):
				if item["level"] > max_risk: max_risk = item["level"]
	
	if report.get("is_obfuscated", false): 
		max_risk = RiskLevel.CRITICAL

	# 2. 颜色与文案逻辑 (使用去风险化文案)
	var style_box = get_theme_stylebox("panel").duplicate()
	var bg_color = Color("#252525") 
	var border_color = Color("#444444") 
	var status_text = ""
	var icon = ""
	var title_color = "#ffffff"

	if max_risk == RiskLevel.INFO:
		icon = "🔵"
		title_color = "#88ccff" 
		status_text = "功能型 Mod (常规)"
		bg_color = Color("#112233") 
		border_color = Color("#335577") 
		
	elif max_risk == RiskLevel.WARNING:
		icon = "⚠️"
		title_color = "orange"
		status_text = "需注意"
		bg_color = Color("#332200") 
		border_color = Color("#775533") 
		
	elif max_risk >= RiskLevel.DANGER:
		icon = "🚫"
		title_color = "#ff4444" 
		status_text = "高风险"
		bg_color = Color("#331111") 
		border_color = Color("#773333") 
		
	else: 
		icon = "✅"
		title_color = "#44ff44" 
		status_text = "未检测出敏感权限"
		bg_color = Color("#113322") 
		border_color = Color("#337755") 

	_apply_style(style_box, bg_color, border_color)

	# 设置顶部文字 (带右键提示)
	status_icon.text = icon
	summary_label.text = "%s  |  [color=%s]%s[/color]  [font_size=10][color=#666666](右键管理)[/color][/font_size]" % [report["filename"], title_color, status_text]

	# 生成详情
	_generate_details_text(report)

# 🟢 渲染白名单信任状态
func render_whitelisted_state(report):
	var style_box = get_theme_stylebox("panel").duplicate()
	_apply_style(style_box, Color("#113311"), Color("#44aa44")) # 鲜艳的绿色
	
	status_icon.text = "🛡️"
	summary_label.text = "%s  |  [color=#44ff44]已信任 (Whitelisted)[/color]  [font_size=10][color=#666666](右键管理)[/color][/font_size]" % report["filename"]
	
	details_box.text = "\n[color=#44ff44]该文件已被您标记为信任。[/color]\nMD5指纹: %s\n\n(右键可移除信任或复制指纹)" % report["md5"]

# 辅助：应用样式
func _apply_style(style_box, bg, border):
	style_box.bg_color = bg
	style_box.border_color = border
	style_box.border_width_left = 4
	style_box.border_width_top = 1
	style_box.border_width_right = 1
	style_box.border_width_bottom = 1
	style_box.corner_radius_top_left = 8
	style_box.corner_radius_top_right = 8
	style_box.corner_radius_bottom_right = 8
	style_box.corner_radius_bottom_left = 8
	add_theme_stylebox_override("panel", style_box)

# 辅助：生成详情文本
func _generate_details_text(report):
	var text = "\n[color=#666666]--- 详细审计报告 ---[/color]\n"
	
	# 状态提示
	if report.get("is_obfuscated", false):
		text += "[color=red]🎲 [高危] 代码混乱度极高 (Entropy: %.2f)[/color]\n" % report["entropy"]
		text += "[color=orange]   └─ 警告: 未检测到 C# 特征，代码可能被加密或加壳。[/color]\n"
	elif report.get("is_resource_heavy", false):
		text += "[color=#eebb00]📦 [体积较大] 检测到大量内嵌资源 (Entropy: %.2f)[/color]\n" % report["entropy"]
		text += "[color=#888888]   └─ 提示: 代码结构清晰，高熵值由资源文件引起，属低风险特征。[/color]\n"
	else:
		text += "[color=#44ff44]🛡️ 代码结构清晰 (Entropy: %.2f)[/color]\n" % report["entropy"]
	
	# 权限列表
	var has_content = false
	for cat in report["permissions"]:
		var items = report["permissions"][cat]
		if items.size() > 0:
			has_content = true
			text += "\n[b]%s 权限:[/b]\n" % cat
			for item in items:
				var prefix = "   • "
				var item_color = "#cccccc"
				
				# 👻 幽灵 / 风险颜色处理
				if item.get("is_ghost", false):
					item_color = "#666666"
					prefix = "   👻 "
				elif item["level"] >= RiskLevel.DANGER: 
					item_color = "#ff6666"
					prefix = "   🚫 "
				elif item["level"] == RiskLevel.WARNING:
					item_color = "orange"
					prefix = "   ⚠️ "
				elif item["level"] == RiskLevel.INFO:
					item_color = "#88ccff"
					prefix = "   🔹 "
				
				text += "[color=%s]%s%s [color=#666666](%s)[/color][/color]\n" % [item_color, prefix, item["desc"], item["keyword"]]
				
				# 行内意图
				if item.get("intent_note", "") != "":
					text += "       [color=#ffffaa]└─ 💡 %s[/color]\n" % item["intent_note"]
	
	if not has_content and not report.get("is_obfuscated", false):
		text += "\n[i]未检测到任何敏感权限调用。[/i]"
		
	details_box.text = text
