//
//  Test_Couch.m
//  CouchCocoa
//
//  Created by Jens Alfke on 6/12/11.
//  Copyright 2011 Couchbase, Inc. All rights reserved.
//

#import "CouchInternal.h"
#import "RESTInternal.h"


#import <SenTestingKit/SenTestingKit.h>


#define AssertWait(OP) ({RESTOperation* i_op = (OP);\
                        STAssertTrue([i_op wait], @"%@ failed: %@", i_op, i_op.error);\
                        i_op = i_op;})


@interface Test_Couch : SenTestCase
{
    CouchServer* _server;
    CouchDatabase* _db;
}
@end


@implementation Test_Couch


- (void) setUp {
    gRESTWarnRaisesException = YES;
    [self raiseAfterFailure];

    _server = [[CouchServer alloc] init];  // local server
    STAssertNotNil(_server, @"Couldn't create server object");
    
    _db = [[_server databaseNamed: @"testdb_temporary"] retain];
    STAssertNotNil(_db, @"Couldn't create database object");
    RESTOperation* op = [_db create];
    if (![op wait]) {
        NSLog(@"NOTE: DB '%@' exists; deleting and re-creating it for tests", _db.relativePath);
        STAssertEquals(op.httpStatus, 412, nil);
        AssertWait([_db DELETE]);
        AssertWait([_db create]);
    }

    gRESTLogLevel = kRESTLogRequestHeaders; // kRESTLogNothing;
}


- (void) tearDown {
    gRESTLogLevel = kRESTLogNothing;
    AssertWait([_db DELETE]);
    [_db release];
    [_server release];
}


- (CouchDocument*) createDocumentWithProperties: (NSDictionary*)properties {
    CouchDocument* doc = [_db untitledDocument];
    STAssertNotNil(doc, @"Couldn't create doc");
    STAssertNil(doc.currentRevisionID, nil);
    STAssertNil(doc.currentRevision, nil);
    STAssertNil(doc.documentID, nil);
    
    AssertWait([doc putProperties: properties]);  // save it!
    
    STAssertNotNil(doc.documentID, nil);
    STAssertNotNil(doc.currentRevisionID, nil);
    STAssertEqualObjects(doc.properties, properties, @"");
    STAssertEquals([_db documentWithID: doc.documentID], doc, @"Saved document wasn't cached");
    NSLog(@"Created %p = %@", doc, doc);
    return doc;
}


- (void) createDocuments: (unsigned)n {
    for (int i=0; i<n; i++) {
        NSDictionary* properties = [NSDictionary dictionaryWithObjectsAndKeys:
                                    @"testDatabase", @"testName",
                                    [NSNumber numberWithInt: i], @"sequence",
                                    nil];
        [self createDocumentWithProperties: properties];
    }
}


- (void) test01_Server {
    NSError* error;
    NSString* version = [_server getVersion: &error];
    STAssertNotNil(version, @"Failed to get server version");
    NSLog(@"Server is version %@", version);
    
    NSArray* uuids = [_server generateUUIDs:5];
    STAssertNotNil(uuids, @"Failed to get UUIDs");
    STAssertEquals(uuids.count, 5U, @"Wrong number of UUIDs");
    NSLog(@"Have some UUIDs: %@", [uuids componentsJoinedByString: @", "]);
    
    for (CouchDatabase *db in [_server getDatabases]) {
        NSLog(@"Database '%@': %ld documents", db.relativePath, (long)[db getDocumentCount]);
    }
}


- (void) test02_CreateDocument {
    NSDictionary* properties = [NSDictionary dictionaryWithObjectsAndKeys:
                                @"testCreateDocument", @"testName",
                                [NSNumber numberWithInt:1337], @"tag",
                                nil];
    CouchDocument* doc = [self createDocumentWithProperties: properties];
    
    NSString* docID = doc.documentID;
    STAssertTrue(docID.length > 10, @"Invalid doc ID: '%@'", docID);
    NSString* currentRevisionID = doc.currentRevisionID;
    STAssertTrue(currentRevisionID.length > 10, @"Invalid doc revision: '%@'", currentRevisionID);

    STAssertEqualObjects(doc.properties, properties, @"Couldn't get doc properties");

    RESTOperation* op = AssertWait([doc GET]);
    STAssertEquals(op.httpStatus, 200, @"GET failed");

    STAssertEqualObjects(doc.properties, properties, @"Couldn't get doc properties after GET");
}


- (void) test02_CreateRevisions {
    NSDictionary* properties = [NSDictionary dictionaryWithObjectsAndKeys:
                                @"testCreateRevisions", @"testName",
                                [NSNumber numberWithInt:1337], @"tag",
                                nil];
    CouchDocument* doc = [self createDocumentWithProperties: properties];
    CouchRevision* rev1 = doc.currentRevision;
    STAssertTrue([rev1.revisionID hasPrefix: @"1-"], nil);
    
    NSMutableDictionary* properties2 = [[properties mutableCopy] autorelease];
    [properties2 setObject: [NSNumber numberWithInt: 4567] forKey: @"tag"];
    RESTOperation* op = [rev1 putProperties: properties2];
    AssertWait(op);
    
    STAssertTrue([doc.currentRevisionID hasPrefix: @"2-"],
                 @"Document revision ID is still %@", doc.currentRevisionID);
    
    CouchRevision* rev2 = op.resultObject;
    STAssertTrue([rev2 isKindOfClass: [CouchRevision class]], nil);
    STAssertEqualObjects(rev2.revisionID, doc.currentRevisionID, nil);
    STAssertTrue(rev2.contentsAreLoaded, nil);
    STAssertEqualObjects(rev2.properties, properties2, nil);
    STAssertEquals(rev2.document, doc, nil);
}


- (void) test03_SaveMultipleDocuments {
    NSMutableArray* docs = [NSMutableArray array];
    for (int i=0; i<5; i++) {
        NSDictionary* properties = [NSDictionary dictionaryWithObjectsAndKeys:
                                    @"testSaveMultipleDocuments", @"testName",
                                    [NSNumber numberWithInt: i], @"sequence",
                                    nil];
        CouchDocument* doc = [self createDocumentWithProperties: properties];
        [docs addObject: doc];
    }
    
    NSMutableArray* revisions = [NSMutableArray array];
    NSMutableArray* revisionProperties = [NSMutableArray array];
    
    for (CouchDocument* doc in docs) {
        CouchRevision* revision = doc.currentRevision;
        STAssertTrue([revision.revisionID hasPrefix: @"1-"],
                     @"Expected 1st revision: %@ in %@", doc.currentRevisionID, doc);
        NSMutableDictionary* properties = revision.properties.mutableCopy;
        [properties setObject: @"updated!" forKey: @"misc"];
        [revisions addObject: revision];
        [revisionProperties addObject: properties];
        [properties release];
    }
    
    AssertWait([_db putChanges: revisionProperties toRevisions: revisions]);
    
    for (CouchDocument* doc in docs) {
        STAssertTrue([doc.currentRevisionID hasPrefix: @"2-"],
                     @"Expected 2nd revision: %@ in %@", doc.currentRevisionID, doc);
        STAssertEqualObjects([doc.currentRevision.properties objectForKey: @"misc"],
                             @"updated!", nil);
    }
}


- (void) test04_DeleteDocument {
    NSDictionary* properties = [NSDictionary dictionaryWithObjectsAndKeys:
                                @"testDeleteDocument", @"testName",
                                nil];
    CouchDocument* doc = [self createDocumentWithProperties: properties];
    STAssertFalse(doc.isDeleted, nil);
    AssertWait([doc DELETE]);
    STAssertTrue(doc.isDeleted, nil);
}


- (void) test05_AllDocuments {
    [self createDocuments: 5];

    // clear the cache so all documents/revisions will be re-fetched:
    [_db clearDocumentCache];
    
    NSLog(@"----- all documents -----");
    CouchQuery* query = [_db getAllDocuments];
    //query.prefetch = YES;
    NSLog(@"Getting all documents: %@", query);
    
    CouchQueryEnumerator* rows = query.rows;
    STAssertEquals(rows.count, 5u, nil);
    STAssertEquals(rows.totalCount, 5u, nil);
    int n = 0;
    for (CouchQueryRow* row in rows) {
        NSLog(@"    --> %@", row);
        CouchDocument* doc = row.document;
        STAssertNotNil(doc, @"Couldn't get doc from query");
        STAssertTrue(doc.currentRevision.contentsAreLoaded, @"QueryRow should have preloaded revision contents");
        NSLog(@"        Properties = %@", doc.properties);
        STAssertNotNil(doc.properties, @"Couldn't get doc properties");
        STAssertEqualObjects([doc propertyForKey: @"testName"], @"testDatabase", @"Wrong doc contents");
        n++;
    }
    STAssertEquals(n, 5, @"Query returned wrong document count");
}


- (void) test06_RowsIfChanged {
    [self createDocuments: 5];
    // clear the cache so all documents/revisions will be re-fetched:
    [_db clearDocumentCache];
    
    CouchQuery* query = [_db getAllDocuments];
    query.prefetch = NO;    // Prefetching prevents view caching, so turn it off
    CouchQueryEnumerator* rows = query.rows;
    STAssertEquals(rows.count, 5u, nil);
    STAssertEquals(rows.totalCount, 5u, nil);
    
    // Make sure the query is cached (view eTag hasn't changed):
    STAssertNil(query.rowsIfChanged, @"View eTag must have changed?");
    
    // Get the rows again to make sure caching isn't messing up:
    rows = query.rows;
    STAssertEquals(rows.count, 5u, nil);
    STAssertEquals(rows.totalCount, 5u, nil);
}

#pragma mark HISTORY

- (void)test07_History {
    NSMutableDictionary* properties = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                @"test06_History", @"testName",
                                [NSNumber numberWithInt:1], @"tag",
                                nil];
    CouchDocument* doc = [self createDocumentWithProperties: properties];
    NSString* rev1ID = doc.currentRevisionID;
    NSLog(@"1st revision: %@", rev1ID);
    STAssertTrue([rev1ID hasPrefix: @"1-"], @"1st revision looks wrong: '%@'", rev1ID);
    STAssertEqualObjects(doc.properties, properties, nil);
    [properties setObject: [NSNumber numberWithInt: 2] forKey: @"tag"];
    STAssertFalse([properties isEqual: doc.properties], nil);
    AssertWait([doc putProperties: properties]);
    NSString* rev2ID = doc.currentRevisionID;
    NSLog(@"2nd revision: %@", rev1ID);
    STAssertTrue([rev2ID hasPrefix: @"2-"], @"2nd revision looks wrong: '%@'", rev2ID);
    
    NSArray* revisions = [doc getRevisionHistory];
    NSLog(@"Revisions = %@", revisions);
    STAssertEquals(revisions.count, 2u, nil);
    
    CouchRevision* rev1 = [revisions objectAtIndex: 0];
    STAssertEqualObjects(rev1.revisionID, rev1ID, nil);
    NSDictionary* gotProperties = rev1.properties;
    STAssertEqualObjects([gotProperties objectForKey: @"tag"], [NSNumber numberWithInt: 1], nil);
    
    CouchRevision* rev2 = [revisions objectAtIndex: 1];
    STAssertEqualObjects(rev2.revisionID, rev2ID, nil);
    STAssertEquals(rev2, doc.currentRevision, @"rev2 = %@; current = %@", rev2, doc.currentRevision);
    gotProperties = rev2.properties;
    STAssertEqualObjects([gotProperties objectForKey: @"tag"], [NSNumber numberWithInt: 2], nil);
    
    STAssertEqualObjects(doc.getConflictingRevisions,
                         [NSArray arrayWithObject: rev2], nil);
}


#pragma mark ATTACHMENTS


- (void) test08_Attachments {
    NSDictionary* properties = [NSDictionary dictionaryWithObjectsAndKeys:
                                @"testAttachments", @"testName",
                                nil];
    CouchDocument* doc = [self createDocumentWithProperties: properties];
    CouchRevision* rev = doc.currentRevision;
    
    STAssertEquals(rev.attachmentNames.count, 0U, nil);
    STAssertNil([rev attachmentNamed: @"index.html"], nil);
    
    CouchAttachment* attach = [rev createAttachmentWithName: @"index.html"
                                                       type: @"text/plain; charset=utf-8"];
    STAssertNotNil(attach, nil);
    STAssertEquals(attach.parent, rev, nil);
    STAssertEquals(attach.revision, rev, nil);
    STAssertEquals(attach.document, doc, nil);
    STAssertEqualObjects(attach.relativePath, @"index.html", nil);
    STAssertEqualObjects(attach.name, attach.relativePath, nil);
    
    NSData* body = [@"This is a test attachment!" dataUsingEncoding: NSUTF8StringEncoding];
    AssertWait([attach PUT: body]);
    
    CouchRevision* rev2 = doc.currentRevision;
    STAssertTrue([rev2.revisionID hasPrefix: @"2-"], nil);
    NSLog(@"Now attachments = %@", rev2.attachmentNames);
    STAssertEqualObjects(rev2.attachmentNames, [NSArray arrayWithObject: @"index.html"], nil);

    attach = [rev2 attachmentNamed: @"index.html"];
    RESTOperation* op = [attach GET];
    AssertWait(op);
    STAssertEqualObjects(op.responseBody.contentType, @"text/plain; charset=utf-8", nil);
    STAssertEqualObjects(op.responseBody.content, body, nil);
    
    AssertWait([doc GET]);

    AssertWait([attach DELETE]);
}


#pragma mark CHANGE TRACKING


- (void) test09_ChangeTracking {
    CouchDatabase* userDB = [_server databaseNamed: @"_users"];
    __block int changeCount = 0;
    [userDB onChange: ^(CouchDocument* doc){ ++changeCount; }];
    userDB.lastSequenceNumber = 0;
    userDB.tracksChanges = YES;

    NSDate* stopAt = [NSDate dateWithTimeIntervalSinceNow: 1.0];
    while (changeCount < 1 && [stopAt timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.0]];
    STAssertTrue(changeCount > 0, nil);
}


- (void) test10_ChangeTrackingNoEchoes {
    __block int changeCount = 0;
    [_db onChange: ^(CouchDocument* doc){ ++changeCount; }];
    _db.tracksChanges = YES;
    
    [self createDocuments: 2];
    
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.0]];
    // We expect that the changes reported by the server won't be notified, because those revisions
    // are already cached in memory.
    STAssertEquals(changeCount, 0, nil);
    
    STAssertEquals(_db.lastSequenceNumber, 2u, nil);
}


- (void) test11_ChangeTrackingNoEchoesAfterTheFact {
    __block int changeCount = 0;
    [_db onChange: ^(CouchDocument* doc){ ++changeCount; }];
    
    [self createDocuments: 5];

    // This time don't turn on change tracking till after the docs are created.
    _db.tracksChanges = YES;

    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.0]];
    // We expect that the changes reported by the server won't be notified, because those revisions
    // are already cached in memory.
    STAssertEquals(changeCount, 0, nil);
    
    STAssertEquals(_db.lastSequenceNumber, 5u, nil);
}


@end