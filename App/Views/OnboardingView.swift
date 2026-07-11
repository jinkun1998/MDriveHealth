/*
 * OnboardingView.swift — 4-step first-run tour: health score, background
 * monitoring, launch at login, and the USB-SMART expectation (the #1 source
 * of one-star confusion).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import ServiceManagement

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var step = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: stepIcon)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(height: 56)

            Text(stepTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            stepBody
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 84, alignment: .top)

            if step == 2 {
                Toggle("Tự chạy khi đăng nhập", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, enable in
                        try? enable ? SMAppService.mainApp.register()
                                    : SMAppService.mainApp.unregister()
                    }
            }

            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            HStack {
                if step > 0 {
                    Button("Quay lại") { step -= 1 }
                }
                Spacer()
                Button(step == stepCount - 1 ? "Bắt đầu dùng" : "Tiếp tục") {
                    if step == stepCount - 1 {
                        isPresented = false
                    } else {
                        step += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private var stepIcon: String {
        ["gauge.with.needle", "bell.badge", "power", "cable.connector"][step]
    }

    private var stepTitle: LocalizedStringKey {
        switch step {
        case 0: return "Điểm sức khoẻ 0–100"
        case 1: return "Theo dõi nền & cảnh báo"
        case 2: return "Tự chạy khi đăng nhập"
        default: return "Lưu ý về ổ USB"
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 0:
            Text("MDriveHealth chấm điểm từng ổ dựa trên các chỉ báo SMART trọng yếu (sector lỗi, media error, độ mòn SSD…). 90+ là Tốt; dưới 50 là lúc cần sao lưu và tính chuyện thay ổ.")
        case 1:
            Text("App âm thầm đọc SMART định kỳ và chỉ lên tiếng khi có chuyện: sức khoẻ giảm, xuất hiện sector lỗi mới, quá nhiệt, hay self-test xong. macOS sẽ hỏi quyền thông báo — hãy bấm Cho phép.")
        case 2:
            Text("Để theo dõi liên tục kể cả sau khi khởi động lại máy, cho app tự chạy khi đăng nhập. Icon nằm gọn trên menu bar, không làm phiền.")
        default:
            Text("macOS không cho đọc SMART qua cầu USB thường — đây là giới hạn hệ điều hành, KHÔNG phải lỗi ổ hay lỗi app. Với ổ USB, mày vẫn đo được tốc độ và kiểm tra dung lượng thật (bắt ổ fake) ở tab Tốc độ.")
        }
    }
}
