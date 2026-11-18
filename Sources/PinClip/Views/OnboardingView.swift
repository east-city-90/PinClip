import SwiftUI

/// 首启/权限缺失引导：嵌在面板中央的卡片（设计方案 §6，参考 CleanShot 引导体验）
struct OnboardingView: View {
    let appState: AppState
    let actions: any PanelActions

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 6) {
                Text("开启屏幕录制权限")
                    .font(.system(size: 15, weight: .semibold))
                Text("PinClip 需要该权限才能截图。\n全程本地处理，不上传任何数据。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            statusRows

            VStack(spacing: 8) {
                if appState.screenPermission {
                    Label("权限已就绪", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                    Button {
                        actions.dismissOnboarding()
                    } label: {
                        Text("开始使用")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 160, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Button {
                        appState.openScreenPermissionSettings()
                    } label: {
                        Label("打开系统设置", systemImage: "gear")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 160, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))

                    Button {
                        Task { await appState.requestScreenPermission() }
                    } label: {
                        Text("重新检测")
                            .font(.system(size: 12))
                            .frame(width: 160, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)

                    // 剪贴板功能无需屏幕权限，允许先逛
                    Button {
                        actions.dismissOnboarding()
                    } label: {
                        Text("先逛逛剪贴板（无需权限）")
                            .font(.system(size: 11))
                            .frame(width: 160, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: Theme.popRadius).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.popRadius)
                .stroke(Theme.line.opacity(0.6), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appState.refreshPermissions() }
        .task {
            // 授权状态轮询：用户在系统设置授权后，状态点实时变绿并自动收起引导
            while true {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                appState.refreshPermissions()
                if appState.screenPermission {
                    // 看到绿色状态短暂停留后自动收起（无需手动点「开始使用」）
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    actions.dismissOnboarding()
                    break
                }
            }
        }
    }

    private var statusRows: some View {
        VStack(spacing: 8) {
            permissionRow(
                name: "屏幕录制",
                required: "截图必需",
                granted: appState.screenPermission
            )
            permissionRow(
                name: "辅助功能",
                required: "自动粘贴（可选）",
                granted: appState.axPermission
            ) {
                if !appState.axPermission {
                    Button("去授权") { appState.openAXPermissionSettings() }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func permissionRow(name: String, required: String, granted: Bool,
                               @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(required).font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                trailing()
            }
        }
    }
}
