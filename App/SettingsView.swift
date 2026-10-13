import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [AIProvider: String] = [:]
    @State private var models: [AIProvider: String] = [:]
    @State private var saved = false
    @State private var exported: SharedURL?
    @AppStorage("conversion.url") private var conversionURL = ""
    var body: some View {
        NavigationStack {
            Form {
                Section { Label("반달 for iPad", systemImage: "moonphase.first.quarter").font(.title2.bold()); Text("학습 공간은 기기에 먼저 저장됩니다.").foregroundStyle(.secondary) }
                Section("AI 연결 · 사용자 API 키") {
                    ForEach(AIProvider.allCases) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(provider.title).font(.headline)
                            SecureField("API 키", text: Binding(get: { keys[provider] ?? "" }, set: { keys[provider] = $0 })).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("모델 ID", text: Binding(get: { models[provider] ?? provider.defaultModel }, set: { models[provider] = $0 })).textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption)
                        }.padding(.vertical, 4)
                    }
                    Button(saved ? "저장했어요" : "AI 설정 저장") {
                        do { for provider in AIProvider.allCases { try KeychainStore.write(keys[provider] ?? "", account: "ai.\(provider.rawValue)"); UserDefaults.standard.set(models[provider] ?? provider.defaultModel, forKey: "ai.model.\(provider.rawValue)") }; saved = true }
                        catch { model.error = error.localizedDescription }
                    }
                    Text("키는 이 기기의 Keychain에 저장됩니다. AI에 전송한 질문과 첨부 자료에는 해당 제공자의 API 요금이 적용됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                SyncSettingsSection(controller: model.sync)
                Section("자료 이동") {
                    Button("현재 과목 내보내기", systemImage: "square.and.arrow.up") { Task { await model.flush(); do { exported = SharedURL(url: try await model.exportExchange()) } catch { model.error = error.localizedDescription } } }
                    Text("반달 교환 파일에는 자료 원본·노트·필기가 포함됩니다. 데스크톱 연결 도구에서 가져올 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    Button("저장 대기 편집 복구") { Task { await model.retryPendingSaves() } }
                    Text("복구 사본은 파일 앱 → 나의 iPad → 반달 → Bandal → Recovery에서 확인할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("오프라인 사전") {
                    Text("English Wiktionary · Kaikki/Wiktextract · koreader-dicts · WordNet")
                    Link("CC BY-SA 4.0 · 출처와 이용 조건", destination: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
                }
                Section("PPT 변환") {
                    TextField("HTTPS 변환 서버 주소", text: $conversionURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("구형 PPT 원본을 이 서버로 전송해 변환합니다. 변환된 PDF는 기기에 보관합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("개발 검증 버전") { Text("0.1.0 · 실제 Pencil 입력과 장시간 녹음은 지원 기기의 실기기 검증이 필요합니다.").font(.caption) }
            }.navigationTitle("설정").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }.onAppear { for provider in AIProvider.allCases { keys[provider] = KeychainStore.read("ai.\(provider.rawValue)") ?? ""; models[provider] = provider.model } }
            .sheet(item: $exported) { ShareSheet(items: [$0.url]) }
    }
}

struct SyncSettingsSection: View {
    @ObservedObject var controller: SyncController
    @AppStorage("sync.url") private var url = ""
    @AppStorage("sync.publishableKey") private var publicKey = ""
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var sentCode = false
    @State private var failure: String?
    @State private var exported: SharedURL?
    var body: some View {
        Section("데스크톱과 동기화") {
            Text(controller.status).font(.subheadline)
            if let email = controller.email {
                Text(email)
                Button("지금 동기화") { Task { await controller.synchronize() } }.disabled(controller.busy)
                Button("로그아웃", role: .destructive) { Task { await controller.signOut() } }
                ForEach(controller.conflicts) { conflict in Button("충돌 사본 내보내기 · \(conflict.local.kind)") { do { exported = SharedURL(url: try controller.exportConflict(conflict)) } catch { failure = error.localizedDescription } } }
            } else {
                Button("Google로 로그인") { login(provider: "google") }.disabled(controller.busy)
                Button("카카오로 로그인") { login(provider: "kakao") }.disabled(controller.busy)
                DisclosureGroup("서버 설정") {
                    TextField("https://project.supabase.co", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Supabase 공개 키", text: $publicKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("프로젝트의 동기화 마이그레이션을 먼저 적용해야 합니다. 서비스 역할 비밀키를 입력하지 마세요.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("이메일", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("비밀번호", text: $password)
                Button("기존 계정으로 로그인") { Task { do { try await controller.signIn(email: email, password: password); password = ""; await controller.synchronize() } catch { failure = error.localizedDescription } } }.disabled(controller.busy || email.isEmpty || password.isEmpty)
                Button("이메일 인증 코드 받기") { Task { do { try await controller.sendCode(email: email); sentCode = true } catch { failure = error.localizedDescription } } }.disabled(controller.busy || email.isEmpty)
                if sentCode {
                    TextField("이메일 인증 코드", text: $code).keyboardType(.numberPad)
                    Button("코드 확인") { Task { do { try await controller.verifyCode(email: email, code: code); await controller.synchronize() } catch { failure = error.localizedDescription } } }.disabled(controller.busy || code.isEmpty)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }.sheet(item: $exported) { ShareSheet(items: [$0.url]) }
    }
    private func login(provider: String) {
        Task { do { try await controller.signIn(provider: provider); await controller.synchronize() } catch { failure = error.localizedDescription } }
    }
}
