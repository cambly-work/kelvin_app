//
//  CrashReportUploader.swift
//  Kelvin
//
//  Очередь и загрузчик отчётов о сбоях.
//  Отправляет только после явного согласия пользователя.
//

import Foundation

/// Состояние элемента очереди отправки
enum UploadQueueItemState: String, Codable {
    case pending       // Ожидает отправки
    case sending       // В процессе отправки
    case retrying      // Повторная попытка после ошибки
    case sent          // Успешно отправлен
    case failed        // Неудача (превышено количество попыток)
    case cancelled     // Отменён пользователем
    
    var isTerminal: Bool {
        return self == .sent || self == .failed || self == .cancelled
    }
}

/// Элемент очереди отправки crash report
struct UploadQueueItem: Codable, Identifiable {
    let id: String           // Уникальный ID элемента очереди
    let reportID: String     // ID отчёта из CrashReportStore
    var state: UploadQueueItemState
    var retryCount: Int
    var lastAttempt: Date?
    var nextRetry: Date?
    var errorMessage: String?
    
    init(reportID: String) {
        self.id = UUID().uuidString
        self.reportID = reportID
        self.state = .pending
        self.retryCount = 0
    }
}

/// Конфигурация uploader
struct CrashUploadConfig {
    /// URL endpoint для отправки отчётов
    let endpoint: URL
    
    /// Максимальный размер payload в байтах
    let maxPayloadSize: Int
    
    /// Таймаут запроса
    let requestTimeout: TimeInterval
    
    /// Минимальная задержка между попытками
    let minRetryDelay: TimeInterval
    
    /// Максимальная задержка между попытками (exponential backoff cap)
    let maxRetryDelay: TimeInterval
    
    /// Максимальное количество попыток
    let maxRetries: Int
    
    static let `default` = CrashUploadConfig(
        endpoint: URL(string: "https://crash-reports.kelvin-mac.app/api/v1/crash-reports")!,
        maxPayloadSize: 512 * 1024, // 512 KB
        requestTimeout: 30,
        minRetryDelay: 60,          // 1 минута
        maxRetryDelay: 3600,        // 1 час
        maxRetries: 5
    )
}

/// Протокол делегата для уведомлений о статусе загрузки
protocol CrashUploadDelegate: AnyObject {
    func uploadQueueDidChange(_ queue: CrashReportUploader)
    func uploadDidStart(_ item: UploadQueueItem)
    func uploadDidComplete(_ item: UploadQueueItem, result: Result<String, Error>)
}

/// Загрузчик отчётов о сбоях с очередью и retry logic
final class CrashReportUploader {
    weak var delegate: CrashUploadDelegate?
    
    private let config: CrashUploadConfig
    private let store: CrashReportStore
    private let sanitizer: CrashReportSanitizer
    
    private let queue = DispatchQueue(label: "kelvin.crash.uploader", attributes: .concurrent)
    private var uploadQueue: [UploadQueueItem] = []
    
    private let session: URLSession
    private var activeTasks: [String: URLSessionTask] = [:]
    
    private let fileManager: FileManager
    private let queueStorageURL: URL
    
    /// Настройка автоматической отправки (только если пользователь включил)
    var autoSendEnabled: Bool {
        UserDefaults.standard.bool(forKey: "CrashReports.AutoSendEnabled")
    }
    
    init(
        config: CrashUploadConfig = .default,
        store: CrashReportStore = .shared,
        sanitizer: CrashReportSanitizer = .shared,
        fileManager: FileManager = .default
    ) {
        self.config = config
        self.store = store
        self.sanitizer = sanitizer
        self.fileManager = fileManager
        
        // Настройка URLSession с отдельной конфигурацией
        let sessionConfig = URLSessionConfiguration.background(withIdentifier: "kelvin.crash.upload")
        sessionConfig.timeoutIntervalForRequest = config.requestTimeout
        sessionConfig.waitsForConnectivity = true
        sessionConfig.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: sessionConfig, delegate: nil, delegateQueue: nil)
        
        // Путь к хранилищу очереди
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let kelvinDir = applicationSupport.appendingPathComponent("Kelvin", isDirectory: true)
        let queueDir = kelvinDir.appendingPathComponent("CrashUploadQueue", isDirectory: true)
        try? fileManager.createDirectory(at: queueDir, withIntermediateDirectories: true)
        self.queueStorageURL = queueDir.appendingPathComponent("queue.json")
        
        loadQueue()
        processQueueIfNeeded()
    }
    
    // MARK: - Public API
    
    /// Добавить отчёт в очередь на отправку
    func enqueue(reportID: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Проверяем, нет ли уже такого отчёта в очереди
            if self.uploadQueue.contains(where: { $0.reportID == reportID && !$0.state.isTerminal }) {
                return
            }
            
            let item = UploadQueueItem(reportID: reportID)
            self.uploadQueue.append(item)
            self.saveQueue()
            
            DispatchQueue.main.async {
                self.delegate?.uploadQueueDidChange(self)
            }
            
            self.processQueueIfNeeded()
        }
    }
    
    /// Отменить отправку конкретного элемента
    func cancel(itemID: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            if let index = self.uploadQueue.firstIndex(where: { $0.id == itemID }) {
                self.uploadQueue[index].state = .cancelled
                
                // Отменяем активную задачу
                if let task = self.activeTasks[itemID] {
                    task.cancel()
                    self.activeTasks.removeValue(forKey: itemID)
                }
                
                self.saveQueue()
                
                DispatchQueue.main.async {
                    self.delegate?.uploadQueueDidChange(self)
                }
            }
        }
    }
    
    /// Получить копию текущей очереди
    func getQueue() -> [UploadQueueItem] {
        queue.sync {
            return uploadQueue
        }
    }
    
    /// Получить элементы, ожидающие действия
    func getPendingItems() -> [UploadQueueItem] {
        queue.sync {
            return uploadQueue.filter { $0.state == .pending || $0.state == .retrying }
        }
    }
    
    /// Очистить завершённые элементы из очереди
    func cleanupCompleted() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let beforeCount = self.uploadQueue.count
            self.uploadQueue.removeAll { $0.state.isTerminal }
            
            if self.uploadQueue.count != beforeCount {
                self.saveQueue()
                
                DispatchQueue.main.async {
                    self.delegate?.uploadQueueDidChange(self)
                }
            }
        }
    }
    
    // MARK: - Private
    
    private func loadQueue() {
        guard fileManager.fileExists(atPath: queueStorageURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: queueStorageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            uploadQueue = try decoder.decode([UploadQueueItem].self, from: data)
        } catch {
            print("Failed to load upload queue: \(error)")
            uploadQueue = []
        }
    }
    
    private func saveQueue() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(uploadQueue)
            try data.write(to: queueStorageURL)
        } catch {
            print("Failed to save upload queue: \(error)")
        }
    }
    
    private func processQueueIfNeeded() {
        // Если авто-отправка выключена, не обрабатываем pending элементы
        guard autoSendEnabled else {
            return
        }
        
        let pendingItems = getPendingItems()
        for item in pendingItems {
            // Проверяем, не пора ли повторная попытка
            if let nextRetry = item.nextRetry, nextRetry > Date() {
                continue
            }
            
            // Проверяем, нет ли уже активной задачи для этого элемента
            if activeTasks[item.id] == nil {
                sendItem(item)
            }
        }
    }
    
    private func sendItem(_ item: UploadQueueItem) {
        // Получаем санитизированный отчёт из хранилища
        guard let reportMetadata = store.getReportMetadata(reportID: item.reportID),
              let sanitizedPayload = sanitizer.loadSanitizedPayload(reportID: item.reportID) else {
            // Отчёт не найден или не санитизирован, помечаем как failed
            markItemFailed(itemID: item.id, error: NSError(domain: "CrashUploader", code: 404, userInfo: [NSLocalizedDescriptionKey: "Report not found or not sanitized"]))
            return
        }
        
        // Проверяем размер payload
        guard sanitizedPayload.count <= config.maxPayloadSize else {
            markItemFailed(itemID: item.id, error: NSError(domain: "CrashUploader", code: 413, userInfo: [NSLocalizedDescriptionKey: "Payload too large"]))
            return
        }
        
        // Обновляем состояние
        updateItemState(itemID: item.id, state: .sending)
        
        DispatchQueue.main.async {
            self.delegate?.uploadDidStart(item)
        }
        
        // Создаём запрос
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Kelvin-Crash-Report/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = sanitizedPayload
        
        // Создаём задачу
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                // Сетевая ошибка - повторяем попытку
                self.handleNetworkError(itemID: item.id, error: error)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                self.markItemFailed(itemID: item.id, error: NSError(domain: "CrashUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
                return
            }
            
            switch httpResponse.statusCode {
            case 200...299:
                // Успех
                let reportServerID = String(data: data ?? Data(), encoding: .utf8) ?? "unknown"
                self.markItemSent(itemID: item.id, serverID: reportServerID)
                
            case 400, 401, 403:
                // Ошибка клиента - не повторяем
                self.markItemFailed(itemID: item.id, error: NSError(domain: "CrashUploader", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Client error: \(httpResponse.statusCode)"]))
                
            case 413:
                // Payload too large
                self.markItemFailed(itemID: item.id, error: NSError(domain: "CrashUploader", code: 413, userInfo: [NSLocalizedDescriptionKey: "Payload exceeds server limit"]))
                
            case 429:
                // Rate limited - ждём дольше
                self.handleRateLimited(itemID: item.id)
                
            case 500...599:
                // Ошибка сервера - повторяем попытку
                self.handleServerError(itemID: item.id, statusCode: httpResponse.statusCode)
                
            default:
                self.markItemFailed(itemID: item.id, error: NSError(domain: "CrashUploader", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected status code: \(httpResponse.statusCode)"]))
            }
        }
        
        queue.async(flags: .barrier) { [weak self] in
            self?.activeTasks[item.id] = task
        }
        
        task.resume()
    }
    
    private func handleNetworkError(itemID: String, error: Error) {
        scheduleRetry(itemID: itemID, error: error)
    }
    
    private func handleServerError(itemID: String, statusCode: Int) {
        scheduleRetry(itemID: itemID, error: NSError(domain: "CrashUploader", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error: \(statusCode)"]))
    }
    
    private func handleRateLimited(itemID: String) {
        // При rate limit увеличиваем задержку значительно
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            if let index = self.uploadQueue.firstIndex(where: { $0.id == itemID }) {
                self.uploadQueue[index].retryCount += 1
                self.uploadQueue[index].lastAttempt = Date()
                self.uploadQueue[index].nextRetry = Date().addingTimeInterval(300) // 5 минут
                self.uploadQueue[index].state = .retrying
                self.uploadQueue[index].errorMessage = "Rate limited by server"
                self.saveQueue()
                
                DispatchQueue.main.async {
                    self.delegate?.uploadQueueDidChange(self)
                }
            }
        }
    }
    
    private func scheduleRetry(itemID: String, error: Error) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            if let index = self.uploadQueue.firstIndex(where: { $0.id == itemID }) {
                var item = self.uploadQueue[index]
                item.retryCount += 1
                
                if item.retryCount >= self.config.maxRetries {
                    item.state = .failed
                    item.errorMessage = error.localizedDescription
                } else {
                    item.state = .retrying
                    item.errorMessage = error.localizedDescription
                    
                    // Exponential backoff
                    let delay = min(
                        self.config.minRetryDelay * pow(2.0, Double(item.retryCount - 1)),
                        self.config.maxRetryDelay
                    )
                    item.nextRetry = Date().addingTimeInterval(delay)
                }
                
                self.uploadQueue[index] = item
                self.saveQueue()
                
                DispatchQueue.main.async {
                    self.delegate?.uploadQueueDidChange(self)
                }
                
                // Планируем следующую попытку
                if item.state == .retrying {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.processQueueIfNeeded()
                    }
                }
            }
        }
    }
    
    private func updateItemState(itemID: String, state: UploadQueueItemState) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            if let index = self.uploadQueue.firstIndex(where: { $0.id == itemID }) {
                self.uploadQueue[index].state = state
                if state == .sending {
                    self.uploadQueue[index].lastAttempt = Date()
                    self.uploadQueue[index].nextRetry = nil
                }
                self.saveQueue()
            }
        }
    }
    
    private func markItemSent(itemID: String, serverID: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            if let index = self.uploadQueue.firstIndex(where: { $0.id == itemID }) {
                self.uploadQueue[index].state = .sent
                self.uploadQueue[index].lastAttempt = Date()
                self.activeTasks.removeValue(forKey: itemID)
                self.saveQueue()
                
                // Обновляем статус в хранилище
                let reportID = self.uploadQueue[index].reportID
                self.store.markReportAsSent(reportID: reportID, serverReportID: serverID)
                
                DispatchQueue.main.async {
                    if let item = self.uploadQueue[index] as UploadQueueItem? {
                        self.delegate?.uploadDidComplete(item, result: .success(serverID))
                    }
                    self.delegate?.uploadQueueDidChange(self)
                }
            }
        }
    }
    
    private func markItemFailed(itemID: String, error: Error) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            if let index = self.uploadQueue.firstIndex(where: { $0.id == itemID }) {
                self.uploadQueue[index].state = .failed
                self.uploadQueue[index].errorMessage = error.localizedDescription
                self.uploadQueue[index].lastAttempt = Date()
                self.activeTasks.removeValue(forKey: itemID)
                self.saveQueue()
                
                DispatchQueue.main.async {
                    if let item = self.uploadQueue[index] as UploadQueueItem? {
                        self.delegate?.uploadDidComplete(item, result: .failure(error))
                    }
                    self.delegate?.uploadQueueDidChange(self)
                }
            }
        }
    }
}

// MARK: - UserDefaults Extension for Auto-Send Setting

extension UserDefaults {
    var crashReportsAutoSendEnabled: Bool {
        get { bool(forKey: "CrashReports.AutoSendEnabled") }
        set { set(newValue, forKey: "CrashReports.AutoSendEnabled") }
    }
}
