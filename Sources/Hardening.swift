import Foundation
import Security

/// Анти-тампер рубежи. Честно: против определённого реверсера всё это — speed-bumps (он зануляет вызовы
/// и переподписывает копию). Цель — поднять стоимость казуального взлома выше $19, а не «неломаемость».
enum Hardening {
    /// Затруднить рантайм-патч гейта отладчиком (ptrace PT_DENY_ATTACH). Только релиз — в DEBUG мешало бы
    /// разработке. ptrace не в публичных заголовках Swift → через dlsym.
    static func denyDebugger() {
        #if !DEBUG
        typealias PtraceFn = @convention(c) (Int32, pid_t, UnsafeMutableRawPointer?, Int32) -> Int32
        if let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "ptrace") {
            let ptrace = unsafeBitCast(sym, to: PtraceFn.self)
            _ = ptrace(31 /* PT_DENY_ATTACH */, 0, nil, 0)
        }
        #endif
    }

    /// Ожидаемый Team ID подписи. nil = не настроено (ad-hoc сборка) → самопроверка ВЫКЛючена.
    /// ПРИ НОТАРИЗАЦИИ вписать реальный Team ID (Developer ID): тогда пропатченная и переподписанная
    /// ad-hoc-копия перестанет давать Pro — `signatureTrusted` вернёт false, `isPro` форсится в false
    /// БЕЗ краша (не наказываем легитимного пользователя падением). Сейчас — no-op.
    static let expectedTeamID: String? = nil

    /// Доверенная ли кодподпись у нашего же процесса. Кэшируем — проверка кодподписи недёшева, а isPro частый.
    static let signatureTrusted: Bool = {
        guard let team = expectedTeamID else { return true }        // не настроено — не ломаем ad-hoc/dev-сборку
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        let reqStr = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqStr, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }()
}
