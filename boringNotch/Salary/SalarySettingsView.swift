import SwiftUI
import Defaults

private struct MilestoneDraft: Identifiable {
    var id: String
    var name: String
    var amount: String
    var symbol: String
    var enabled: Bool
    init(_ value: SalaryMilestone) {
        id = value.id; name = value.name; amount = String(format: "%.2f", Double(value.cents) / 100); symbol = value.symbol; enabled = value.enabled
    }
}

struct SalarySettingsView: View {
    @ObservedObject private var store = SalaryStore.shared
    @State private var tab = 0
    @State private var salary = ""
    @State private var profile = SalaryProfile()
    @State private var targets: [MilestoneDraft] = []
    @State private var preferences = SalaryPreferences()
    @State private var reference = ""
    @State private var preview: (String, SalarySnapshot)?
    @State private var message = ""
    @State private var isError = false
    @State private var correction = ""
    @State private var corrected: SalarySnapshot?
    @State private var confirmCorrection = false
    @State private var confirmClear = false
    @State private var exceptionDate = Date()
    @State private var exceptionWork = false
    private let labels = ["薪酬与作息", "我的快乐清单", "偏好与隐私"]
    private let symbols = ["clock.badge.checkmark", "gift", "slider.horizontal.3"]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(labels[tab]).font(.system(size: 24, weight: .semibold))
                        Text(tab == 0 ? "把时间，换算成生活的一点甜。" : tab == 1 ? "不是攒够了才值得快乐，是每一小步都值得。" : "怎么陪你上班，由你说了算。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("V1 · 本地体验版").font(.system(size: 10, weight: .medium)).padding(8).background(.white.opacity(0.06), in: Capsule())
                }.padding(24)
                if store.privacy && tab != 2 {
                    VStack(spacing: 16) {
                        Image(systemName: "eye.slash").font(.system(size: 38)).foregroundStyle(SalaryPalette.mint)
                        Text("金额和快乐清单都藏好了。")
                        Button("关闭隐私模式后编辑") { if store.setPrivacy(false) { preferences.privacy = false } }.buttonStyle(SalaryPrimaryButtonStyle())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Group {
                        if tab == 0 { profileForm }
                        else if tab == 1 { targetForm }
                        else { preferencesForm }
                    }.formStyle(.grouped)
                    if tab == 0 { profileActions }
                }
                if let welcome = store.welcomeMessage {
                    Label(welcome, systemImage: "sparkles").font(.system(size: 12)).foregroundStyle(SalaryPalette.mint).padding(.horizontal, 24).padding(.vertical, 8)
                }
                if !message.isEmpty {
                    Label(message, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(isError ? .orange : SalaryPalette.mint).padding(.horizontal, 24).padding(.vertical, 10)
                }
                if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .tint(SalaryPalette.mint)
        .onAppear(perform: load)
        .alert("只修正今日估算？", isPresented: $confirmCorrection) {
            Button("取消", role: .cancel) {}
            Button("确认修正") { perform { try store.correctToday(monthlyCents: SalaryEngine.moneyCents(correction)); message = "今日已修正，历史与未来设置保持不变。" } }
        } message: {
            Text("今日金额将变为 \(SalaryEngine.formatYuan(cents: corrected?.earnedCents(at: Date()) ?? 0))。新跨过的门槛不会补播。")
        }
        .alert("清除薪酬数据？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { perform { try store.clearSalaryData(); load(); message = "薪酬数据已清除。" } }
        } message: { Text("删除本应用的工资配置、日记录、成就与文案历史。音乐与文件架数据不受影响。") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 31)).foregroundStyle(SalaryPalette.mint).padding(.top, 30)
            Text("薪动日常").font(.system(size: 27, weight: .semibold, design: .rounded))
            Text("今天也没有白上班。") .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.bottom, 28)
            ForEach(0..<3) { index in
                Button { tab = index; message = "" } label: {
                    Label(labels[index], systemImage: symbols[index]).font(.system(size: 13, weight: tab == index ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(tab == index ? SalaryPalette.mint.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(tab == index ? SalaryPalette.mint : .white.opacity(0.6))
                }.buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("想先看看效果？").font(.system(size: 12, weight: .medium))
                Button(store.isDemo ? "退出演示" : "播放奶茶演示") {
                    if store.isDemo { store.endDemo() } else { store.startDemo() }
                    SalarySettingsWindow.shared.hide()
                    BoringViewCoordinator.shared.currentView = .salary
                    store.requestOpenIsland?()
                }.buttonStyle(.bordered).tint(SalaryPalette.mint)
                Text("演示使用虚构工资，\n不会写入你的成就。") .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineSpacing(3)
            }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            Button("通用设置") { SettingsWindowController.shared.showWindow() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).padding(.top, 10)
            Button { NSApplication.shared.terminate(nil) } label: {
                Label("退出薪动日常", systemImage: "power")
                    .font(.system(size: 12)).padding(.vertical, 6)
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            .keyboardShortcut("q", modifiers: .command)
            .help("退出应用，停止显示灵动岛；薪酬配置保留。")
        }.padding(20).frame(width: 208).frame(maxHeight: .infinity).background(Color.black.opacity(0.55))
    }

    private var profileForm: some View {
        Form {
            Section {
                HStack {
                    Text("固定月薪")
                    Spacer()
                    Text("¥").foregroundStyle(.secondary)
                    TextField("", text: $salary, prompt: Text("例如 12000.00"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 150)
                        .multilineTextAlignment(.trailing).accessibilityLabel("固定月薪，单位元")
                }
                Picker("工资口径", selection: $profile.tax) { ForEach(SalaryTax.allCases, id: \.self) { Text($0.label).tag($0) } }
                Text("只做工资的时间折算，不连接银行，也不会计算个税。") .font(.caption).foregroundStyle(.secondary)
            } header: { Text("01  给时间一个价格") }
            Section {
                HStack {
                    Text("工作日"); Spacer()
                    ForEach(Array([2,3,4,5,6,7,1].enumerated()), id: \.element) { index, day in
                        Button {
                            if profile.schedule.weekdays.contains(day) { profile.schedule.weekdays.remove(day) } else { profile.schedule.weekdays.insert(day) }
                        } label: {
                            Text(["一","二","三","四","五","六","日"][index])
                                .font(.system(size: 12, weight: .semibold)).frame(width: 29, height: 26)
                                .foregroundStyle(profile.schedule.weekdays.contains(day) ? Color.black : Color.white.opacity(0.7))
                                .background(profile.schedule.weekdays.contains(day) ? SalaryPalette.mint : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                            .accessibilityLabel("周\(["一","二","三","四","五","六","日"][index])\(profile.schedule.weekdays.contains(day) ? "已选" : "未选")")
                    }
                }
                HStack { Text("上下班"); Spacer(); timePicker("上班", minute: $profile.schedule.startMinute); Text("至").foregroundStyle(.secondary); timePicker("下班", minute: $profile.schedule.endMinute) }
                Toggle("有午休", isOn: $profile.schedule.hasBreak)
                if profile.schedule.hasBreak {
                    HStack { Text("午休时间"); Spacer(); timePicker("午休开始", minute: $profile.schedule.breakStartMinute); Text("至").foregroundStyle(.secondary); timePicker("午休结束", minute: $profile.schedule.breakEndMinute) }
                    Toggle("午休也计薪", isOn: $profile.schedule.paidBreak)
                }
                TextField("工作时区", text: $profile.schedule.timeZoneID)
                Text("未自动包含节假日与调休。首版支持同一天内的一段班次，不支持夜班。") .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("临时休息 / 补班") {
                    HStack {
                        DatePicker("日期", selection: $exceptionDate, displayedComponents: .date).labelsHidden()
                        Toggle("这天上班", isOn: $exceptionWork)
                        Button("加入计划") {
                            let key = SalaryEngine.dayKey(exceptionDate, timeZoneID: TimeZone.current.identifier)
                            let today = SalaryEngine.dayKey(Date(), timeZoneID: profile.schedule.timeZoneID)
                            guard key >= today else { message = "过去日期不回溯修改。"; isError = true; return }
                            profile.schedule.exceptions[key] = exceptionWork; preview = nil
                        }
                    }
                    ForEach(profile.schedule.exceptions.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key); Spacer(); Text(profile.schedule.exceptions[key] == true ? "补班" : "休息").foregroundStyle(.secondary)
                            Button("移除") { profile.schedule.exceptions.removeValue(forKey: key); preview = nil }.buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("02  定好营业时间") }
            Section {
                if store.configured {
                    DisclosureGroup("今天的工资填错了？") {
                        TextField("用于修正今日的月薪", text: $correction)
                        Button("预览今日修正") { perform { corrected = try store.correctedToday(monthlyCents: SalaryEngine.moneyCents(correction)); confirmCorrection = true } }
                        Text("仅修正今日金额，不改变未来配置，也不补播成就。") .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: salary) { _, _ in preview = nil }
        .onChange(of: profile) { _, _ in preview = nil }
    }

    private var profileActions: some View {
        VStack(alignment: .leading, spacing: 8) {
                if let preview {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(preview.0) 起生效").font(.headline).foregroundStyle(SalaryPalette.mint)
                        Text("该日预计 \(SalaryEngine.formatYuan(cents: preview.1.dayCents)) · 每小时 \(SalaryEngine.formatYuan(cents: preview.1.hourlyYuan * 100))") .monospacedDigit()
                        Text("当天已开工则次日生效；切换时区按原计划下一工作日上班时刻生效，不补算新时区已过去的时段。月中变更后合计可能不同于月薪。") .font(.caption).foregroundStyle(.secondary)
                        Button("按此方案保存") { perform { try store.saveProfile(preparedProfile()); message = "已保存。把鼠标移到屏幕顶部，看看工资开始营业。"; self.preview = nil } }
                            .buttonStyle(SalaryPrimaryButtonStyle())
                    }
                } else {
                    Button(store.configured ? "预览变更" : "看看我的时薪") {
                        perform { preview = try store.previewProfile(preparedProfile()); message = "" }
                    }.buttonStyle(SalaryPrimaryButtonStyle())
                }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var targetForm: some View {
        Form {
            Section {
                ForEach($targets) { $item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("启用", isOn: $item.enabled).labelsHidden()
                            Image(systemName: item.symbol).foregroundStyle(SalaryPalette.gold).frame(width: 24)
                            TextField("", text: $item.name, prompt: Text("快乐名称")).labelsHidden().textFieldStyle(.roundedBorder).accessibilityLabel("快乐名称")
                            Text("¥").foregroundStyle(.secondary)
                            TextField("", text: $item.amount, prompt: Text("金额")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 85).accessibilityLabel("目标金额，单位元")
                            Button { targets.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("删除这个目标")
                        }
                        if let event = store.realTodayEvents.first(where: { $0.id == "milestone:" + item.id }) {
                            Label("今日已达成 · \(event.name)（\(SalaryEngine.formatYuan(cents: Double(event.cents)))）", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(SalaryPalette.mint)
                        }
                    }.padding(.vertical, 4)
                }
                Button { targets.append(MilestoneDraft(.init(name: "我的小快乐", cents: 10000, symbol: "gift.fill"))) } label: { Label("再加一份快乐", systemImage: "plus") }.disabled(targets.count >= 5)
            } header: { Text("每日小目标 · 最多5项") }
            Section {
                Text("每个目标独立比较，不扣除今日收入。不表示你已经买过，也不能把所有物品当成同时可花的余额。") .font(.callout).foregroundStyle(.secondary)
                Text("价格是你自己的选择。关闭全部目标后，就安静地看时间和工资增长。") .font(.callout).foregroundStyle(.secondary)
                Button("保存快乐清单") {
                    perform {
                        let items = try targets.map { item in SalaryMilestone(id: item.id, name: item.name, cents: try SalaryEngine.moneyCents(item.amount), symbol: item.symbol, enabled: item.enabled) }
                        try store.saveMilestones(items); message = "快乐清单已保存。已跨过的门槛不会补弹。"
                    }
                }.buttonStyle(SalaryPrimaryButtonStyle())
                Button("预览一条奶茶反馈") {
                    guard !store.privacy else { message = "请先关闭隐私模式，再预览快乐反馈。"; isError = true; return }
                    SalarySettingsWindow.shared.hide(); store.previewCelebration(); store.requestOpenIsland?()
                }
            }
        }
    }

    private var preferencesForm: some View {
        Form {
            Section {
                Picker("陪你上班的语气", selection: $preferences.tone) { ForEach(SalaryTone.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Text(preferences.tone == .gentle ? "一杯喜欢的奶茶，已经赚到了。" : preferences.tone == .playful ? "奶茶钱到手。今天先替珍珠打工到这里。" : "今日份窝囊费估算完毕，建议本人离场。") .font(.callout).foregroundStyle(.secondary)
                Toggle("反馈时播放轻提示音", isOn: $preferences.sound)
                Toggle("隐私模式", isOn: Binding(get: { store.privacy }, set: { if store.setPrivacy($0) { preferences.privacy = $0 } }))
                Button(store.quiet ? "恢复自动提示" : "安静到下班") { store.toggleQuiet(); preferences.quietUntil = store.data.preferences.quietUntil }
                Text("全屏、锁屏、隐私与安静模式不自动展开。当前不自动读取系统专注状态。") .font(.caption).foregroundStyle(.secondary)
            } header: { Text("陪伴感，不是存在感轰炸") }
            Section {
                Toggle("开启自填薪资参考", isOn: $preferences.referenceEnabled)
                if preferences.referenceEnabled && !store.privacy {
                    TextField("参考月薪（元）", text: $reference)
                    Picker("参考口径", selection: $preferences.referenceTax) { ForEach(SalaryTax.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Toggle("在对比卡片中偶尔说一句嘴替", isOn: $preferences.referenceHumor)
                    Text("仅在主动打开时显示。同口径才能比较；自填值不是城市平均工资。") .font(.caption).foregroundStyle(.secondary)
                }
                if store.privacy { Text("参考金额已隐藏。").foregroundStyle(.secondary) }
            } header: { Text("一份参考，不是对你的定价") }
            Section {
                Button("保存偏好") {
                    perform {
                        var value = preferences
                        value.privacy = store.privacy; value.quietUntil = store.data.preferences.quietUntil
                        value.referenceLastShown = store.data.preferences.referenceLastShown
                        if value.referenceEnabled { value.referenceCents = try SalaryEngine.moneyCents(reference) }
                        try store.savePreferences(value); message = "偏好已保存。用你喜欢的方式上班。"
                    }
                }.buttonStyle(SalaryPrimaryButtonStyle())
                Link("开源许可与声明", destination: URL(string: "https://github.com/wekobear/salary-island/blob/feature/salary-island-v1/THIRD-PARTY-NOTICES.md")!)
                Button("清除薪酬数据…", role: .destructive) { confirmClear = true }
                Text("薪酬数据保存在这台 Mac，不需要账号。") .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func timePicker(_ title: String, minute: Binding<Int>) -> some View {
        DatePicker(title, selection: Binding(get: {
            Calendar.current.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { value in
            let c = Calendar.current.dateComponents([.hour, .minute], from: value)
            minute.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }), displayedComponents: .hourAndMinute).labelsHidden().accessibilityLabel(title).fixedSize()
    }
    private func preparedProfile() throws -> SalaryProfile {
        var value = profile; value.monthlyCents = try SalaryEngine.moneyCents(salary)
        if store.configured {
            let day = SalaryEngine.dayKey(Date(), timeZoneID: value.schedule.timeZoneID)
            let old = store.editingProfile.schedule.exceptions
            if old[day] != value.schedule.exceptions[day] {
                let effective = try SalaryEngine.effectiveDay(for: value, versions: store.data.versions, now: Date())
                if effective != day { throw SalaryStoreError("今天的班次已经开始，不能再切换今天的休息 / 补班。可调整未来日期。") }
            }
        }
        return value
    }
    private func load() {
        profile = store.editingProfile
        salary = profile.monthlyCents > 0 ? String(format: "%.2f", Double(profile.monthlyCents) / 100) : ""
        targets = store.data.milestones.map(MilestoneDraft.init)
        preferences = store.data.preferences
        reference = preferences.referenceCents > 0 ? String(format: "%.2f", Double(preferences.referenceCents) / 100) : ""
        preview = nil
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); isError = false }
        catch { message = error.localizedDescription; isError = true }
    }
}

private struct SalaryPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(SalaryPalette.mint.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
