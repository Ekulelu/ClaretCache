//
//  KVStorage.swift
//  ClaretCacheDemo
//
//  Created by HZheng on 2019/7/28.
//  Copyright © 2019 com.ClaretCache. All rights reserved.
//

import UIKit
import SQLite3

#if os(iOS) && canImport(UIKit)
import UIKit.UIApplication
#endif


enum KVStorageType {
    case KVStorageTypeFile
    case KVStorageTypeSQLite
    case KVStorageTypeMixed
}

/*
 File:
 /path/
 /manifest.sqlite
 /manifest.sqlite-shm
 /manifest.sqlite-wal
 /data/
 /e10adc3949ba59abbe56e057f20f883e
 /e10adc3949ba59abbe56e057f20f883e
 /trash/
 /unused_file_or_folder
 
 SQL:
 create table if not exists manifest (
 key                 text,
 filename            text,
 size                integer,
 inline_data         blob,
 modification_time   integer,
 last_access_time    integer,
 extended_data       blob,
 primary key(key)
 );
 create index if not exists last_access_time_idx on manifest(last_access_time);
 */

class KVStorage: NSObject {
    /**
     KVStorageItem is used by `KVStorage` to store key-value pair and meta data.
     Typically, you should not use this class directly.
     */
    class KVStorageItem: NSObject {
        var key: String?            ///< key
        var value: Data?            ///< value
        var fileName: String?       ///< fileName (nil if inline)
        var size: Int = 0           ///< value's size in bytes
        var modTime: Int = 0        ///< modification unix timestamp
        var accessTime: Int = 0     ///< last access unix timestamp
        var extendedData: Data?     ///< extended data (nil if no extended data)
    }
    
    
    
    fileprivate let kMaxErrorRetryCount = 8
    fileprivate let kMinRetryTimeInterval = 2.0
    fileprivate let kPathLengthMax = PATH_MAX - 64
    fileprivate let kDBFileName = "manifest.sqlite"
    fileprivate let kDBShmFileName = "manifest.sqlite-shm"
    fileprivate let kDBWalFileName = "manifest.sqlite-wal"
    fileprivate let kDataDirectoryName = "data"
    fileprivate let kTrashDirectoryName = "trash"
    
    fileprivate var trashQueue : DispatchQueue
    fileprivate var path: URL
    fileprivate var dbPath: URL
    fileprivate var dataPath: URL
    fileprivate var trashPath: URL
    fileprivate var db: OpaquePointer? = nil
    fileprivate var dbStmtCache: Dictionary<String, Any>?
    fileprivate var dbLastOpenErrorTime: TimeInterval = 0
    fileprivate var dbOpenErrorCount: UInt = 0
    fileprivate(set) var type: KVStorageType
    fileprivate var errorLogsEnabled: Bool = true
    
    init?(path: URL, type: KVStorageType) {
        guard path.absoluteString.count > 0, path.absoluteString.count <= kPathLengthMax else {
            print("KVStorage init error: invalid path: [\(path)].")
            return nil;
        }
        
        self.path = path;
        self.type = type;
        trashQueue = OS_dispatch_queue_serial(label: "com.iteatime.cache.disk.trash")
        dataPath = path.appendingPathComponent(kDataDirectoryName)
        trashPath = path.appendingPathComponent(kTrashDirectoryName)
        dbPath = path.appendingPathComponent(kDBFileName)
        do {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: dataPath, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: trashPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return nil;
        }
        
        super.init();
        if !dbOpen() || !dbInitialize() {
            // db file may broken...
            dbClose()
            reset() // rebuild
            if !dbOpen() || !dbInitialize() {
                dbClose()
                print("KVStorage init error: fail to open sqlite db.")
                return nil;
            }
        }
        fileEmptyTrashInBackground()
    }
    
    deinit {
        #if os(iOS) && canImport(UIKit)
        #endif
        let taskID = UIApplication.sharedExtensionApplication()?.beginBackgroundTask(expirationHandler: nil);
        dbClose()
        #if os(iOS) && canImport(UIKit)
        if let task = taskID {
            UIApplication.sharedExtensionApplication()?.endBackgroundTask(task)
        }
        #endif
    }
    
    //MARK: private
    fileprivate func reset() {
        do {
            try FileManager.default.removeItem(at: path.appendingPathComponent(kDBFileName))
            try FileManager.default.removeItem(at: path.appendingPathComponent(kDBShmFileName))
            try FileManager.default.removeItem(at: path.appendingPathComponent(kDBWalFileName))
            try fileMoveAllToTrash()
            fileEmptyTrashInBackground()
        } catch {
            print("reset error: \(error)")
        }
    }
    
    
    //MARK: File
    
    fileprivate func fileWrite(fileName: String, data: Data) throws {
        try data.write(to: dataPath.appendingPathComponent(fileName))
    }

    fileprivate func fileRead(fileName: String) throws -> Data? {
        return try Data.init(contentsOf: dataPath.appendingPathComponent(fileName))
    }
    
    fileprivate func deleteFile(fileName: String) throws {
        try FileManager.default.removeItem(at: dataPath.appendingPathComponent(fileName))
    }
    
    fileprivate func fileMoveAllToTrash() throws {
        let uuid = UUID().uuidString
        let tmpPath = trashPath.appendingPathComponent(uuid)
        try FileManager.default.moveItem(at: dataPath, to: tmpPath)
        try FileManager.default.createDirectory(at: dataPath, withIntermediateDirectories: true, attributes: nil)
    }
    
    // empty the trash if failed at last time
    fileprivate func fileEmptyTrashInBackground() {
        let trashPath = self.trashPath
        DispatchQueue.global().async {
            let fileMgr = FileManager.default
            do {
                let directoryContents = try fileMgr.contentsOfDirectory(atPath: trashPath.absoluteString)
                for path in directoryContents {
                    let fullPath = trashPath.appendingPathComponent(path)
                    try fileMgr.removeItem(at: fullPath)
                }
            } catch {
                print("remove trash error: \(error)")
            }
        }
    }
    
    //MARK: DataBase
    
    fileprivate func dbOpen() -> Bool {
        guard db == nil else {
            return true
        }
        let result = sqlite3_open(dbPath.absoluteString, &db)
        guard result == SQLITE_OK else {
            db = nil
            dbStmtCache = nil
            dbLastOpenErrorTime = CACurrentMediaTime()
            dbOpenErrorCount+=1
            if errorLogsEnabled {
                print("\(#function) line:\(#line) sqlite open failed (\(result)).")
            }
            return false
        }
        dbStmtCache = Dictionary()
        dbLastOpenErrorTime = 0
        dbOpenErrorCount = 0;
        return true
    }
    
    @discardableResult
    fileprivate func dbClose() -> Bool {
        guard db != nil else {
            return true
        }
        
        var retry = false;
        var stmtFinalized = false;
        dbStmtCache = nil
        repeat {
            retry = false
            let result = sqlite3_close(db!)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                if !stmtFinalized {
                    stmtFinalized = true
                    var stmt = sqlite3_next_stmt(db!, nil)
                    while stmt != nil {
                        sqlite3_finalize(stmt);
                        stmt = sqlite3_next_stmt(db!, nil)
                        retry = true
                    }
                }
            } else if result != SQLITE_OK {
                if (errorLogsEnabled) {
                    print("\(#function) line:\(#line) sqlite close failed (\(result).")
                }
            }
        } while(retry)
        db = nil
        return true
    }
    
    fileprivate func dbCheck() -> Bool {
        guard db == nil else {
            return true
        }
        if dbOpenErrorCount < kMaxErrorRetryCount &&
            CACurrentMediaTime() - dbLastOpenErrorTime > kMinRetryTimeInterval {
                return dbOpen() && dbInitialize()
        } else {
            return false
        }
    }
    
    fileprivate func dbInitialize() -> Bool {
        let sql = "pragma journal_mode = wal; pragma synchronous = normal; create table if not exists manifest (key text, filename text, size integer, inline_data blob, modification_time integer, last_access_time integer, extended_data blob, primary key(key)); create index if not exists last_access_time_idx on manifest(last_access_time);"
        return dbExecute(sql)
    }
    
    fileprivate func dbCheckpoint() {
        guard dbCheck() else {
            return
        }
        // Cause a checkpoint to occur, merge `sqlite-wal` file to `sqlite` file.
        sqlite3_wal_checkpoint(db, nil)
    }
    
    fileprivate func dbExecute(_ sql: String) -> Bool {
        guard sql.count > 0, dbCheck() else {
            return false
        }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
    
    fileprivate func dbPrepareStmt(_ sql: String) -> OpaquePointer? {
        guard dbCheck(), sql.count > 0, dbStmtCache != nil else {
            return nil
        }
        var stmt = dbStmtCache?[sql] as? OpaquePointer
        if stmt == nil {
            let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard result == SQLITE_OK else {
                if (errorLogsEnabled) {
                    print("\(#function) line:\(#line) sqlite stmt prepare error (\(result)): \(errorMessage)")
                }
                return nil
            }
            dbStmtCache?[sql] = stmt
        } else {
            sqlite3_reset(stmt)
        }
        return stmt
    }
    
    fileprivate var errorMessage: String {
        if let errorPointer = sqlite3_errmsg(db) {
            let errorMessage = String(cString: errorPointer)
            return errorMessage
        } else {
            return "No error message provided from sqlite."
        }
    }
    
    fileprivate func dbJoinedKeys(_ keys: Array<Any>) -> String {
        var string = ""
        let max = keys.count
        for i in 0..<max {
            string.append("?")
            if i + 1 != max {
                string.append(",")
            }
        }
        return string
    }
    
    fileprivate func dbBindJoinedKeys(keys: Array<String>, stmt: OpaquePointer, fromIndex index : Int) {
        let max = keys.count
        for i in 0..<max {
            let key = keys[i] as NSString
            sqlite3_bind_text(stmt, Int32(index + i), key.utf8String, -1, nil)
        }
    }
    
    fileprivate func dbSave(key: String, value: Data, fileName: String, extendedData: Data) -> Bool {
        let sql = "insert or replace into manifest (key, filename, size, inline_data, modification_time, last_access_time, extended_data) values (?1, ?2, ?3, ?4, ?5, ?6, ?7);"
        guard let stmt = dbPrepareStmt(sql) else {
            return false
        }
        let timestamp = Int32(time(nil))
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (fileName as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(value.count))
        if fileName.count == 0 {
            sqlite3_bind_blob(stmt, 4, (value as NSData).bytes, Int32(value.count), nil)
        } else {
            sqlite3_bind_blob(stmt, 4, nil, 0, nil)
        }
        sqlite3_bind_int(stmt, 5, timestamp)
        sqlite3_bind_int(stmt, 6, timestamp)
        sqlite3_bind_blob(stmt, 7, (extendedData as NSData).bytes,  Int32(extendedData.count), nil)
        
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite insert error (\(result): (\(errorMessage))")
            }
            return false
        }
        return true
    }
    
    fileprivate func dbUpdateAccessTime(_ key: String) -> Bool {
        let sql = "update manifest set last_access_time = ?1 where key = ?2;"
        guard let stmt = dbPrepareStmt(sql) else {
            return false
        }
        sqlite3_bind_int(stmt, 1, Int32(time(nil)))
        sqlite3_bind_text(stmt, 2, (key as NSString).utf8String, -1, nil)
        let result = sqlite3_step(stmt)
        if (result != SQLITE_DONE) {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite update error (\(result): (\(errorMessage))")
            }
            return false
        }
        return true
    }
    
    fileprivate func dbUpdateAccessTimes(_ keys: Array<String>) -> Bool {
        guard dbCheck() else {
            return false
        }
        let sql = "update manifest set last_access_time = \(Int32(time(nil))) where key in (\(dbJoinedKeys(keys)));"
        var stmtPointer: OpaquePointer?
        var result = sqlite3_prepare_v2(db, sql, -1, &stmtPointer, nil)
        guard result == SQLITE_OK, let stmt = stmtPointer else {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite stmt prepare error (\(result): (\(errorMessage))")
            }
            return false
        }
        dbBindJoinedKeys(keys: keys, stmt: stmt, fromIndex: 1)
        result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if (result != SQLITE_DONE) {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite update error (\(result): (\(errorMessage))")
            }
            return false
        }
        return true
    }
    
    fileprivate func dbDeleteItem(_ key: String) -> Bool {
        let sql = "delete from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else {
            return false
        }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        let result = sqlite3_step(stmt)
        if (result != SQLITE_DONE) {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite delete error (\(result): (\(errorMessage))")
            }
            return false
        }
        return true
    }
    
    fileprivate func dbDeleteItems(_ keys: Array<String>) -> Bool {
        guard dbCheck() else {
            return false
        }
        let sql = "delete from manifest where key in (\(dbJoinedKeys(keys));"
        var stmtPointer: OpaquePointer?
        var result = sqlite3_prepare_v2(db, sql, -1, &stmtPointer, nil)
        guard result == SQLITE_OK, let stmt = stmtPointer else {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite stmt prepare error (\(result): (\(errorMessage))")
            }
            return false
        }
        dbBindJoinedKeys(keys: keys, stmt: stmt, fromIndex: 1)
        result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if (result == SQLITE_ERROR) {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite delete error (\(result): (\(errorMessage))")
            }
            return false
        }
        return true
    }
    
    fileprivate func dbDeleteItem(sql: String, param: Int32) -> Bool {
        guard let stmt = dbPrepareStmt(sql) else {
            return false
        }
        sqlite3_bind_int(stmt, 1, param);
        let result = sqlite3_step(stmt)
        if (result != SQLITE_DONE) {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite delete error (\(result): (\(errorMessage))")
            }
            return false
        }
        return true
    }
    
    fileprivate func dbDeleteItemsWithSizeLargerThan(size: Int) -> Bool {
        return dbDeleteItem(sql: "delete from manifest where size > ?1;", param: Int32(size))
    }
    
    fileprivate func dbDeleteItemsWithSizeEarlierThan(time: Int) -> Bool {
        return dbDeleteItem(sql: "delete from manifest where last_access_time < ?1;", param: Int32(time))
    }
    
    fileprivate func dbGetItemFromStmt(stmt: OpaquePointer, excludeInlineData: Bool) -> KVStorageItem {
        let item = KVStorageItem()
        var i: Int32 = 0
        item.key = String(cString: UnsafePointer(sqlite3_column_text(stmt, i)))
        i += 1
        item.fileName = String(cString: UnsafePointer(sqlite3_column_text(stmt, i)))
        i += 1
        item.size = Int(sqlite3_column_int(stmt, Int32(i)))
        i += 1
        let inline_data: UnsafeRawPointer? = excludeInlineData ? nil : sqlite3_column_blob(stmt, i);
        let inline_data_length = excludeInlineData ? 0 : sqlite3_column_bytes(stmt, i)
        i += 1
        if inline_data_length > 0 && (inline_data != nil) {
            item.value = NSData(bytes:inline_data, length:Int(inline_data_length)) as Data
        }
        item.modTime = Int(sqlite3_column_int(stmt, i))
        i += 1
        item.accessTime = Int(sqlite3_column_int(stmt, i))
        i += 1
        let extended_data: UnsafeRawPointer? = sqlite3_column_blob(stmt, i)
        let extended_data_length = sqlite3_column_bytes(stmt, i)
        if extended_data_length > 0 && (extended_data != nil) {
            item.extendedData = NSData(bytes:extended_data, length:Int(extended_data_length)) as Data
        }
        return item
    }
    
    fileprivate func dbGetItem(key: String, excludeInlineData: Bool) -> KVStorageItem? {
        let sql = excludeInlineData ? "select key, filename, size, modification_time, last_access_time, extended_data from manifest where key = ?1;" : "select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else {
            return nil
        }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        var item: KVStorageItem?
        let result = sqlite3_step(stmt)
        if (result == SQLITE_ROW) {
            item = dbGetItemFromStmt(stmt: stmt, excludeInlineData: excludeInlineData)
        } else {
            if (result != SQLITE_DONE) {
                if errorLogsEnabled {
                    print("\(#function) line:(\(#line) sqlite query error (\(result): (\(errorMessage))")
                }
            }
        }
        return item
    }
    
    fileprivate func dbGetItems(keys: Array<String>, excludeInlineData: Bool) -> Array<KVStorageItem>? {
        guard dbCheck() else {
            return nil
        }
        let sql: String
        if (excludeInlineData) {
            sql = "select key, filename, size, modification_time, last_access_time, extended_data from manifest where key in (\(dbJoinedKeys(keys)));"
        } else {
            sql = "select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key in (\(dbJoinedKeys(keys))"
        }
        var stmtPointer: OpaquePointer?
        var result = sqlite3_prepare_v2(db, sql, -1, &stmtPointer, nil)
        guard result == SQLITE_OK, let stmt = stmtPointer else {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite stmt prepare error (\(result): (\(errorMessage))")
            }
            return nil
        }
        dbBindJoinedKeys(keys: keys, stmt: stmt, fromIndex: 1)
        var items: Array<KVStorageItem>?
        items = Array<KVStorageItem>()
        repeat {
            result = sqlite3_step(stmt)
            if (result == SQLITE_ROW) {
                items?.append(dbGetItemFromStmt(stmt: stmt, excludeInlineData: excludeInlineData))
            } else if (result == SQLITE_DONE) {
                break;
            } else {
                if errorLogsEnabled {
                    print("\(#function) line:(\(#line) sqlite query error (\(result): (\(errorMessage))")
                }
                items = nil
                break
            }
        } while(true)
        sqlite3_finalize(stmt)
        return items
    }
    
    fileprivate func dbGetValue(key: String) -> Data? {
        let sql = "select inline_data from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else {
            return nil
        }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        let result = sqlite3_step(stmt)
        if (result == SQLITE_ROW) {
            let inline_data: UnsafeRawPointer? = sqlite3_column_blob(stmt, 0)
            let inline_data_length = sqlite3_column_bytes(stmt, 0)
            guard inline_data_length > 0 && (inline_data != nil) else {
                return nil
            }
            return NSData(bytes:inline_data, length:Int(inline_data_length)) as Data
        } else {
            if (result != SQLITE_DONE) {
                if errorLogsEnabled {
                    print("\(#function) line:(\(#line) sqlite query error (\(result): (\(errorMessage))")
                }
            }
            return nil
        }
    }
    
    fileprivate func dbGetFilename(key: String) -> String? {
        let sql = "select filename from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else {
            return nil
        }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        let result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            return String(cString: UnsafePointer(sqlite3_column_text(stmt, 0)))
        } else {
            if (result != SQLITE_DONE) {
                if errorLogsEnabled {
                    print("\(#function) line:(\(#line) sqlite query error (\(result): (\(errorMessage))")
                }
            }
            return nil
        }
    }
    
    fileprivate func dbGetFileNames(keys: Array<String>) -> Array<String>? {
        guard dbCheck() else {
            return nil
        }
        let sql = "select filename from manifest where key in (\(dbJoinedKeys(keys)));"
        var stmtPointer: OpaquePointer?
        var result = sqlite3_prepare_v2(db, sql, -1, &stmtPointer, nil)
        guard result == SQLITE_OK, let stmt = stmtPointer else {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite stmt prepare error (\(result): (\(errorMessage))")
            }
            return nil
        }
        dbBindJoinedKeys(keys: keys, stmt: stmt, fromIndex: 1)
        var fileNames: Array<String>?
        fileNames = Array<String>()
        repeat {
            result = sqlite3_step(stmt)
            if (result == SQLITE_ROW) {
                fileNames?.append(String(cString: UnsafePointer(sqlite3_column_text(stmt, 0))))
            } else if (result == SQLITE_DONE) {
                break;
            } else {
                if errorLogsEnabled {
                    print("\(#function) line:(\(#line) sqlite query error (\(result): (\(errorMessage))")
                }
                fileNames = nil
                break
            }
        } while(true)
        sqlite3_finalize(stmt)
        return fileNames
    }
    
    fileprivate func dbGetFilenames(sql: String, param: Int32) -> Array<String>? {
        guard let stmt = dbPrepareStmt(sql) else {
            return nil
        }
        sqlite3_bind_int(stmt, 1, Int32(param));
        var fileNames: Array<String>?
        fileNames = Array<String>()
        repeat {
            let result = sqlite3_step(stmt)
            if (result == SQLITE_ROW) {
                fileNames?.append(String(cString: UnsafePointer(sqlite3_column_text(stmt, 0))))
            } else if (result == SQLITE_DONE) {
                break;
            } else {
                if errorLogsEnabled {
                    print("\(#function) line:(\(#line) sqlite query error (\(result): (\(errorMessage))")
                }
                fileNames = nil
                break
            }
        } while(true)
        sqlite3_finalize(stmt)
        return fileNames
    }
    
    fileprivate func dbGetFilenamesWithSizeLargerThan(size: Int) -> Array<String>? {
        let sql = "select filename from manifest where size > ?1 and filename is not null;"
        return dbGetFilenames(sql: sql, param: Int32(size))
    }
    
    fileprivate func dbGetFilenamesWithSizeEarlierThan(time: Int) -> Array<String>? {
        let sql = "select filename from manifest where last_access_time < ?1 and filename is not null;"
        return dbGetFilenames(sql: sql, param: Int32(time))
    }
    
    fileprivate func dbGetItemSizeInfoOrderByTimeAscWithLimit(count: Int) -> Array<KVStorageItem>? {
        let sql = "select key, filename, size from manifest order by last_access_time asc limit ?1;"
        guard let stmt = dbPrepareStmt(sql) else {
            return nil
        }
        var items: Array<KVStorageItem>?
        items = Array<KVStorageItem>()
        repeat {
            let result = sqlite3_step(stmt)
            if (result == SQLITE_ROW) {
                let item = KVStorageItem()
                item.key = String(cString: UnsafePointer(sqlite3_column_text(stmt, 0)))
                item.fileName = String(cString: UnsafePointer(sqlite3_column_text(stmt, 1)))
                item.size = Int(sqlite3_column_int(stmt, 2))
                items?.append(item)
            } else if (result == SQLITE_DONE) {
                break;
            } else {
                if errorLogsEnabled {
                    print("\(#function) line:(\(#line) sqlite query error (\(result): (\(errorMessage))")
                }
                items = nil
                break
            }
        } while(true)
        sqlite3_finalize(stmt)
        return items
    }
    
    fileprivate func dbGetItemCount(key: String) -> Int {
        let sql = "select count(key) from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else {
            return -1
        }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite query error (\(result): (\(errorMessage))")
            }
            return -1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
    
    fileprivate func dbGetInt(_ sql: String) -> Int {
        guard let stmt = dbPrepareStmt(sql) else {
            return -1
        }
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            if errorLogsEnabled {
                print("\(#function) line:(\(#line) sqlite query error (\(result): (\(errorMessage))")
            }
            return -1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
    
    fileprivate func dbGetTotalItemSize() -> Int {
        return dbGetInt("select sum(size) from manifest;")
    }
    
    fileprivate func dbGetTotalItemCount() -> Int {
        return dbGetInt("select count(*) from manifest;")
    }
}