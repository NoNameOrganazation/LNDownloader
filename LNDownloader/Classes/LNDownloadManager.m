//
//  LNDownloadManager.m
//  LNDownloader
//
//  Created by Lenny on 2018/12/17.
//

#import "LNDownloadManager.h"
#import "LNDownloadTask.h"
#import <CommonCrypto/CommonDigest.h>

const NSInteger LNUnlimitedConcurrentDownloadCount = 0;
NSString * const LNFilesTotalSizePlistName = @"LNFilesTotalSizePlistName.plist";



#define LN_MAX_FILE_EXTENSION_LENGTH (NAME_MAX - CC_MD5_DIGEST_LENGTH * 2 - 1)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline NSString * _Nonnull LNDownloadFileNameForURL(NSURL * _Nullable URL) {
    if(!URL) return @"LNDownloadNoName";
    NSString *URLString = URL.absoluteString;
    const char *str = URLString.UTF8String;
    if (str == NULL) {
        str = "";
    }
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSString *ext = URL.pathExtension;
    NSString *originFileName = URL.lastPathComponent;
    // File system has file name length limit, we need to check if ext is too long, we don't add it to the filename
    if (originFileName.length > LN_MAX_FILE_EXTENSION_LENGTH) {
        if (ext.length > LN_MAX_FILE_EXTENSION_LENGTH) {
            ext = @"";
        }else{
           ext = [NSString stringWithFormat:@".%@", ext];
        }
    }else{
        ext = originFileName;
    }
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15], ext];
    return filename;
}
#pragma clang diagnostic pop


#define LNFileName(URL) LNDownloadFileNameForURL(URL)

#define LN_LOCK(_taskLock) dispatch_semaphore_wait(_taskLock, DISPATCH_TIME_FOREVER)
#define LN_UNLOCK(_taskLock) dispatch_semaphore_signal(_taskLock)

#define LN_SAFE_BLOCK(Block, ...) ({ !Block ? nil : Block(__VA_ARGS__); })

@interface LNDownloadManager () <NSURLSessionDelegate, NSURLSessionDataDelegate>
{
    dispatch_semaphore_t _taskLock;
}

@property(nonatomic, strong) NSMutableDictionary   *downloadTasksDic;
@property(nonatomic, strong) NSMutableArray        *downloadingTasks;
@property(nonatomic, strong) NSMutableArray        *downloadWaitingTasks;

@property(nonatomic, strong) NSOperationQueue *delegateQueue;

@property(nonatomic, copy) NSString  *filesTotalSizePlistPath;


@end

@implementation LNDownloadManager

@synthesize downloadFileDirectory = _downloadFileDirectory;

+ (instancetype)defaultManager
{
    static LNDownloadManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _downloadTasksDic = [[NSMutableDictionary alloc] init];
        _downloadingTasks = [[NSMutableArray alloc] init];
        _downloadWaitingTasks = [[NSMutableArray alloc] init];
        _taskLock = dispatch_semaphore_create(1);
        _maxConcurrentDownloadCount = LNUnlimitedConcurrentDownloadCount;
        _delegateQueue = [[NSOperationQueue alloc] init];
        _delegateQueue.name = @"com.LNDownloader.LNDownloadManager.delegateQueue";
    }
    return self;
}

#pragma mark - Public
#pragma mark - download
- (void)download:(NSURL *)URL
           state:(LNDownloadStateBlock)stateBlock
        progress:(LNDownloadProgressBlock)progressBlock
      completion:(LNDownloadCompletionBlock)completionBlock{
    
    [self download:URL destPath:nil state:stateBlock progress:progressBlock completion:completionBlock];
}


- (void)download:(NSURL *)URL
        destPath:(NSString *)destPath
           state:(LNDownloadStateBlock)stateBlock
        progress:(LNDownloadProgressBlock)progressBlock
      completion:(LNDownloadCompletionBlock)completionBlock
{
    if(!URL) {
        LN_SAFE_BLOCK(stateBlock, LNDownloadStateFailed);
        LN_SAFE_BLOCK(progressBlock, 0,0,1);
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:0 userInfo:@{@"reason":@"URLString is nil"}];
        LN_SAFE_BLOCK(completionBlock, NO, nil, error);
        return;
    }

    NSString *fileName = LNFileName(URL);
    NSString *filePath = [self fullFilePathWithFileName:fileName];
    NSInteger totalSize = [self totalSizeofFileName:fileName];
    NSInteger receivedSize = [self downloadedSizeWithFilePath:filePath];
    if(receivedSize != 0 && receivedSize == totalSize){// Task is Finish
        LN_SAFE_BLOCK(stateBlock, LNDownloadStateCompleted);
        LN_SAFE_BLOCK(progressBlock, receivedSize, totalSize, 1.0);
        LN_SAFE_BLOCK(completionBlock, YES, filePath, nil);
        return;
    }
    LNDownloadTask *existTask = [self getTaskWithURL:URL];
    if(existTask){
        LNDownloadTask *associateTask = [[LNDownloadTask alloc] init];
        associateTask.progressBlock = progressBlock;
        associateTask.stateBlock = stateBlock;
        associateTask.completionBlock = completionBlock;
        [associateTask setupWithOtherTask:existTask];
        CGFloat progress = 0;
        if(totalSize > 0){
            progress = 1.0 * receivedSize / totalSize;
        }
        LN_SAFE_BLOCK(progressBlock, receivedSize, totalSize, progress);
        [existTask.associateTasks addObject:associateTask];
        [self resumeTask:existTask];
        return;
    }
    
    NSURLSessionDataTask *dataTask = [self createDataTaskWithURL:URL];
    LNDownloadTask *task = [[LNDownloadTask alloc] init];
    task.dataTask = dataTask;
    task.URL = URL;
    task.fileName = fileName;
    task.filePath = filePath;
    task.destPath = destPath;
    task.receivedSize = receivedSize;
    task.writeStream = [NSOutputStream outputStreamToFileAtPath:filePath append:YES];
    task.stateBlock = stateBlock;
    task.progressBlock = progressBlock;
    task.completionBlock = completionBlock;
    [self startTask:task];
}

- (NSURLSessionDataTask *)createDataTaskWithURL:(NSURL *)URL
{
    NSString *fileName = LNFileName(URL);
    NSString *filePath = [self fullFilePathWithFileName:fileName];
    NSInteger receivedSize =  [self downloadedSizeWithFilePath:filePath];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    // 读取已下载内容，以支持断线续传
    [request setValue:[NSString stringWithFormat:@"bytes=%ld-", (long)receivedSize] forHTTPHeaderField:@"Range"];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:(id)self delegateQueue:_delegateQueue];
    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:[request copy]];
    dataTask.taskDescription = fileName;///通过fileName将dataTask和LNDownloadTask进行关联
    return dataTask;
}

- (void)suspendDownloadOfURL:(NSURL *)URL{
    LNDownloadTask *task = [self getTaskWithURL:URL];
    if(!task) return;
    [self suspendTask:task];
}

- (void)suspendAllDownloads{
    [self suspendAllDownloadTasks];
}


- (void)resumeDownloadOfURL:(NSURL *)URL{
    LNDownloadTask *task = [self getTaskWithURL:URL];
    if(!task) return;
    [self resumeTask:task];
}

- (void)resumeAllDownloads{
    [self resumeAllDownloadTasks];
}


- (void)cancelDownloadOfURL:(NSURL *)URL{
    LNDownloadTask *task = [self getTaskWithURL:URL];
    if(!task) return;
    [self cancelTask:task];
}

- (void)cancelAllDownloads{
    [self cancelAllDownloadTasks];
}

#pragma mark - files

- (NSString *)fileFullPathOfURL:(NSURL *)URL{
    return [self fullFilePathWithURL:URL];
}

- (CGFloat)downloadedProgressOfURL:(NSURL *)URL{
    
    NSString *fileName = LNFileName(URL);
    NSString *filePath = [self fullFilePathWithFileName:fileName];
    NSInteger receivedSize =  [self downloadedSizeWithFilePath:filePath];
    NSInteger totalSize = [self totalSizeofFileName:fileName];
    
    if(receivedSize != 0 && receivedSize == totalSize){
        return 1.0;
    }
    if (totalSize == 0) {
        return 0.0;
    }
    return 1.0 * receivedSize / totalSize;
}

- (void)deleteFile:(NSString *)fileName{
    NSMutableDictionary *totalSizeDict = [self getTotalSizeInfo];
    [totalSizeDict removeObjectForKey:fileName];
    [self saveTotalSizeInfo:[totalSizeDict copy]];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *filePath = [self.downloadFileDirectory stringByAppendingPathComponent:fileName];
    if (![fileManager fileExistsAtPath:filePath]) {
        return;
    }
    [fileManager removeItemAtPath:filePath error:nil];
}

- (void)deleteFileOfURL:(NSURL *)URL{
    [self cancelDownloadOfURL:URL];
    NSString *fileName = LNDownloadFileNameForURL(URL);
    [self deleteFile:fileName];
}

- (void)deleteAllFiles{
    
    [self cancelAllDownloadTasks];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *fileNames = [fileManager contentsOfDirectoryAtPath:self.downloadFileDirectory error:nil];
    for (NSString *fileName in fileNames) {
        NSString *filePath = [self.downloadFileDirectory stringByAppendingPathComponent:fileName];
        [fileManager removeItemAtPath:filePath error:nil];
    }
}


#pragma mark - Private
#pragma mark - Download task safe operation

- (LNDownloadTask *)getTaskWithFileName:(NSString *)fileName
{
    if(!fileName) return nil;
    LNDownloadTask *task = nil;
    LN_LOCK(_taskLock);
    task = [_downloadTasksDic objectForKey:fileName];
    LN_UNLOCK(_taskLock);
    return task;
}

- (LNDownloadTask *)getTaskWithURL:(NSURL *)URL
{
    NSString *fileName = LNDownloadFileNameForURL(URL);
    return [self getTaskWithFileName:fileName];
}

//- (BOOL)isDownloadingTask:(LNDownloadTask *)task
//{
//    if(!task) return NO;
//    BOOL loading = NO;
//    LN_LOCK(_taskLock);
//    if([_downloadingTasks containsObject:task]){
//        loading = YES;
//    }
//    LN_UNLOCK(_taskLock);
//
//    return loading;
//}


- (BOOL)isCompletionURL:(NSURL *)URL
{
    NSString *fileName = LNFileName(URL);
    NSString *filePath = [self fullFilePathWithFileName:fileName];
    NSInteger receivedSize =  [self downloadedSizeWithFilePath:filePath];
    NSInteger totalSize = [self totalSizeofFileName:fileName];
    if(receivedSize != 0 && receivedSize == totalSize){
        return YES;
    }
    return NO;
}


- (BOOL)isCompletionTask:(LNDownloadTask *)task
{
    if(!task) return NO;
    NSInteger receivedSize = [self downloadedSizeWithFilePath:task.filePath];
    NSInteger totalSize = [self totalSizeofFileName:task.fileName];
    if(receivedSize != 0 && receivedSize == totalSize){
        return YES;
    }
    return NO;
}


- (BOOL)isNeedWaiting
{
    BOOL ret = YES;
    if(_maxConcurrentDownloadCount == LNUnlimitedConcurrentDownloadCount || _downloadingTasks.count < _maxConcurrentDownloadCount){//start when un limit or downloading count less than max count
        ret = NO;
    }
    return ret;
}

- (void)startTask:(LNDownloadTask *)task
{
    if(!task) return;
    LN_LOCK(_taskLock);
    [_downloadTasksDic setObject:task forKey:task.fileName];
    if([self isNeedWaiting]){//start when un limit or downloading count less than max count
        task.state = LNDownloadStateWaiting;
        [_downloadWaitingTasks addObject:task];
    }else{
        task.state = LNDownloadStateRunning;
        [_downloadingTasks addObject:task];
        [self _doResumeTask:task];
    }
    LN_UNLOCK(_taskLock);
}

- (void)resumeTask:(LNDownloadTask *)task
{
    if(!task) return;
    LN_LOCK(_taskLock);
    if(![self isNeedWaiting]){//start when un limit or downloading count less than max count
        task.state = LNDownloadStateRunning;
        if(![_downloadingTasks containsObject:task]){
            [_downloadingTasks addObject:task];
        }
        [self _doResumeTask:task];
    }else{
        task.state = LNDownloadStateWaiting;
        if(![_downloadWaitingTasks containsObject:task]){
            [_downloadWaitingTasks addObject:task];
        }
    }
    LN_UNLOCK(_taskLock);
}

- (void)_doResumeTask:(LNDownloadTask *)task
{
    if(task.dataTask.state == NSURLSessionTaskStateCompleted || task.dataTask.state == NSURLSessionTaskStateCanceling){
        task.dataTask = [self createDataTaskWithURL:task.URL];
    }
    [task.dataTask resume];
}

- (void)resumeNextTask
{
    LN_LOCK(_taskLock);
    if(_downloadWaitingTasks.count > 0 && ![self isNeedWaiting]){
        //start when un limit or downloading count less than max count
        LNDownloadTask *task = [_downloadWaitingTasks firstObject];
        task.state = LNDownloadStateRunning;
        [self _doResumeTask:task];
        [_downloadWaitingTasks removeObjectAtIndex:0];
        [_downloadingTasks addObject:task];
    }
    LN_UNLOCK(_taskLock);
}

- (void)resumeAllDownloadTasks
{
    if (self.downloadTasksDic.count == 0) {
        return;
    }
    LN_LOCK(_taskLock);
    NSArray *downloadTasks = self.downloadTasksDic.allValues;
    for (LNDownloadTask *task in downloadTasks) {
        if (![self isNeedWaiting]) {
            task.state = LNDownloadStateRunning;
            [self.downloadingTasks addObject:task];
            [self _doResumeTask:task];
        } else {
            task.state = LNDownloadStateWaiting;
            [self.downloadWaitingTasks addObject:task];
        }
    }
    LN_UNLOCK(_taskLock);
}

- (void)cancelTask:(LNDownloadTask *)task
{
    if(!task) return;
    LN_LOCK(_taskLock);
    task.state = LNDownloadStateCanceled;
    [_downloadTasksDic removeObjectForKey:task.fileName];
    if([_downloadWaitingTasks containsObject:task]){
        [_downloadWaitingTasks removeObject:task];
    }else{
        [task.dataTask cancel];
        [_downloadingTasks removeObject:task];
    }
    LN_SAFE_BLOCK(task.progressBlock, 0, 0, 0);
    [task closeWriteStream];
    LN_UNLOCK(_taskLock);
    /**取消一个任务，填充下一个任务*/
    [self resumeNextTask];
}

- (void)cancelAllDownloadTasks
{
    LN_LOCK(_taskLock);
    if(self.downloadTasksDic.count > 0){
        for (LNDownloadTask *task in self.downloadTasksDic.allValues) {
            task.state = LNDownloadStateCanceled;
            [task.dataTask cancel];
        }
        [self.downloadWaitingTasks removeAllObjects];
        [self.downloadingTasks removeAllObjects];
        [self.downloadTasksDic removeAllObjects];
    }
    LN_UNLOCK(_taskLock);
}

- (void)suspendTask:(LNDownloadTask *)task
{
    if(!task) return;
    LN_LOCK(_taskLock);
    task.state = LNDownloadStateSuspended;
    if([_downloadWaitingTasks containsObject:task]){
        if(task.state == NSURLSessionTaskStateRunning){
            [task.dataTask suspend];
        }
        [_downloadWaitingTasks removeObject:task];
        
    }else{
        [task.dataTask suspend];
        [_downloadingTasks removeObject:task];
    }
    LN_UNLOCK(_taskLock);
    [self resumeNextTask];
}

- (void)suspendAllDownloadTasks
{
    LN_LOCK(_taskLock);
    if (self.downloadTasksDic.count == 0) {
        return;
    }
    if(self.downloadWaitingTasks.count > 0){
        for (LNDownloadTask *task in self.downloadWaitingTasks) {
            task.state = LNDownloadStateSuspended;
            if(task.state == NSURLSessionTaskStateRunning){
                [task.dataTask suspend];
            }
        }
        [self.downloadWaitingTasks removeAllObjects];
    }

    if(self.downloadingTasks.count > 0){
        for (LNDownloadTask *task in self.downloadingTasks) {
            task.state = LNDownloadStateSuspended;
            [task.dataTask suspend];
        }
        [self.downloadingTasks removeAllObjects];
    }
    LN_UNLOCK(_taskLock);
}

- (void)endTask:(LNDownloadTask *)task isSucceed:(BOOL)isSucceed
{
    if(!task) return;
    LN_LOCK(_taskLock);
    [task closeWriteStream];
    if(isSucceed){
        task.state = LNDownloadStateCompleted;
    }else{
        task.state = LNDownloadStateFailed;
    }
    [_downloadTasksDic removeObjectForKey:task.fileName];
    [_downloadingTasks removeObject:task];
    [_downloadWaitingTasks removeObject:task];
    LN_UNLOCK(_taskLock);
}


#pragma mark - Download file operation
- (void)setDownloadFileDirectory:(NSString *)downloadFileDirectory
{
    _downloadFileDirectory = downloadFileDirectory;
    [self createFileDirectory:_downloadFileDirectory];
}

- (NSString *)downloadFileDirectory
{
    if(!_downloadFileDirectory){
        _downloadFileDirectory = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject] stringByAppendingPathComponent:NSStringFromClass([self class])];
        [self createFileDirectory:_downloadFileDirectory];
    }
    return _downloadFileDirectory;
}

- (NSString *)filesTotalSizePlistPath
{
    if(!_filesTotalSizePlistPath){
        _filesTotalSizePlistPath = [self.downloadFileDirectory stringByAppendingPathComponent:LNFilesTotalSizePlistName];
    }
    return _filesTotalSizePlistPath;
}

- (void)createFileDirectory:(NSString *)downloadFileDirectory
{
    BOOL isDirectory = NO;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isExists = [fileManager fileExistsAtPath:downloadFileDirectory isDirectory:&isDirectory];
    if (!isExists || !isDirectory) {
        [fileManager createDirectoryAtPath:downloadFileDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

- (NSInteger)downloadedSizeWithFilePath:(NSString *)filePath{
    
    NSError *error = nil;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
    if (!fileAttributes) {
        return 0;
    }
    if(error){
        NSLog(@"Error:%@", error);
        return 0;
    }
    return [fileAttributes[NSFileSize] integerValue];
}

- (NSString *)fullFilePathWithURL:(NSURL *)URL
{
    NSString *fileName = LNDownloadFileNameForURL(URL);
    return [self.downloadFileDirectory stringByAppendingPathComponent:fileName];
}

- (NSString *)fullFilePathWithFileName:(NSString *)fileName
{
    if(!fileName){
        fileName = NSStringFromClass([self class]);
    }
    return [self.downloadFileDirectory stringByAppendingPathComponent:fileName];
}

#pragma mark - TotalSizeInfo
- (NSInteger)totalSizeofFileWithURL:(NSURL *)URL
{
    NSString *fileName = LNDownloadFileNameForURL(URL);
    return [self totalSizeofFileName:fileName];
}

- (NSInteger)totalSizeofFileName:(NSString *)fileName
{
    if(!fileName) return 0;
    NSInteger totalSize = 0;
    NSDictionary *dict = [self getTotalSizeInfo];
    if(dict && dict[fileName]){
        totalSize = [dict[fileName] integerValue];
    }
    return totalSize;
}

- (NSMutableDictionary *)getTotalSizeInfo
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:self.filesTotalSizePlistPath];
    if(!dict){
        dict = [NSMutableDictionary dictionary];
    }
    return dict;
}

- (void)saveTotalSizeInfo:(NSDictionary *)totalSizeInfo
{
    if(!totalSizeInfo) return;
    [totalSizeInfo writeToFile:self.filesTotalSizePlistPath atomically:YES];
}


#pragma mark - NSURLSessionDelegate
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    NSString *fileName = dataTask.taskDescription;
    LNDownloadTask *task = [self getTaskWithFileName:fileName];
    if(!task) {
        completionHandler(NSURLSessionResponseAllow);
        return;
    };
    
    [task openWriteStream];
    NSInteger totalSize = (long)response.expectedContentLength + [self downloadedSizeWithFilePath:task.filePath];
    task.totalSize = totalSize;
    NSMutableDictionary *dict = [self getTotalSizeInfo];
    [dict setObject:@(task.totalSize) forKey:task.fileName];
    [self saveTotalSizeInfo:[dict copy]];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    NSString *fileName = dataTask.taskDescription;
    LNDownloadTask *task = [self getTaskWithFileName:fileName];
    if(!task) return;
    [task.writeStream write:data.bytes maxLength:data.length];
    NSInteger receivedSize = [self downloadedSizeWithFilePath:task.filePath];
    task.receivedSize = receivedSize;
    CGFloat progress = 0;
    if(task.totalSize > 0){
        progress = 1.0 * receivedSize / task.totalSize;
    }
    if (task.state == LNDownloadStateSuspended || task.state == LNDownloadStateCanceled) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        LN_SAFE_BLOCK(task.progressBlock, receivedSize, task.totalSize, progress);
        if(task.associateTasks.count > 0){
            for (LNDownloadTask *item in task.associateTasks) {
                LN_SAFE_BLOCK(item.progressBlock, receivedSize, task.totalSize, progress);
            }
        }
    });
    
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)dataTask
didCompleteWithError:(NSError *)error
{
    NSString *fileName = dataTask.taskDescription;
    LNDownloadTask *task = [self getTaskWithFileName:fileName];
    if(!task) return;
    if(task.destPath){
        NSError *error;
        if (![[NSFileManager defaultManager] moveItemAtPath:task.filePath toPath:task.destPath error:&error]) {
            NSLog(@"moveItemAtPath error: %@", error);
        }
    }
    if (task.state == LNDownloadStateSuspended || task.state == LNDownloadStateCanceled) {
        return;
    }
    BOOL isSucceed = error == nil ? YES : NO;
    [self endTask:task isSucceed:isSucceed];
    dispatch_async(dispatch_get_main_queue(), ^{
        task.completionBlock(isSucceed, task.filePath, error);
        LN_SAFE_BLOCK(task.completionBlock, isSucceed, task.filePath, error);
        if(task.associateTasks.count > 0){
            for (LNDownloadTask *item in task.associateTasks) {
                LN_SAFE_BLOCK(item.completionBlock, isSucceed, task.filePath, error);
            }
        }
    });
//    NSLog(@"Resume next task");
    [self resumeNextTask];
}

@end
