// Copyright (c) 2006-2008 Simon Fell
//
// Permission is hereby granted, free of charge, to any person obtaining a 
// copy of this software and associated documentation files (the "Software"), 
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, 
// and/or sell copies of the Software, and to permit persons to whom the 
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included 
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS 
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
// THE SOFTWARE.
//

#import "CreateActivityController.h"
#import "Email.h"
#import "ZKSforce.h"
#import "ZKDescribeSObject_Additions.h"
#import "SObjectPermsWrapper.h"
#import "WhoWhat.h"
#import "Attachment.h"

static NSString *WHO_FIELDS = @"Id, Email, Name, FirstName, LastName";

@interface CreateActivityController (private)
- (void)saveCheckedWhats;
@end

@implementation CreateActivityController


+ (void)initialize {
	NSArray *keys = [NSArray arrayWithObjects:@"email", nil];
    [self setKeys:keys triggerChangeNotificationsForDependentKey:@"emailSubject"];
}

- (id)init {
	self = [super init];
	whoSearchResults = [[NSArray array] retain];
	whatObjectTypes = nil;
	return self;
}

- (void)dealloc {
	[sforce release];
	[whatObjectTypes release];
	[whoSearchText release];
	[whatSearchText release];
	[whoSearchResults release];
	[whatResultsTableSource release];
	[availableEntities release];
	[super dealloc];
}

- (IBAction)cancel:(id)sender {
	[NSApp abortModal];
}

- (void)windowWillClose:(NSNotification *)notification {
	[NSApp abortModal];
}

- (BOOL)hasEntity:(NSString *)entity {
	if (availableEntities == nil)
		availableEntities = [[sforce describeGlobal] retain];
	return [availableEntities containsObject:entity];
}

- (ZKSObject *)selectedWho {
	NSArray *sel = [whoSearchController selectedObjects];
	if ([sel count] == 0) return nil;
	return [sel objectAtIndex:0];
}

- (ZKSObject *)selectedWhat {
	int sel = [whatSearchResults selectedRow];
	if (sel < 0) return nil;
	return [[whatResultsTableSource results] objectAtIndex:sel];
}

-(void)updateWhoWhat:(WhoWhat **)whoWhat from:(ZKSObject *)o {
	if (o == nil) {
		[*whoWhat release];
		*whoWhat = nil;
	} else {
		if (*whoWhat == nil) 
			*whoWhat = [[WhoWhat alloc] initWithClient:sforce];
		[*whoWhat setSobject:o];
	}
}

-(NSArray *)selectedWhoWhats {
	[self updateWhoWhat:&selectedWho from:[self selectedWho]];
	[self updateWhoWhat:&selectedWhat from:[self selectedWhat]];
	NSMutableArray *s = [NSMutableArray arrayWithCapacity:2];
	if (selectedWho != nil)  [s addObject:selectedWho];
	if (selectedWhat != nil) [s addObject:selectedWhat];
	return s;
}

// there was a selection change in one of the results tables, notifiy that this changes the selectedWhoWhats property
-(void)tableViewSelectionDidChange:(NSNotification *)aNotification {
	[self willChangeValueForKey:@"selectedWhoWhats"];
	[self selectedWhoWhats];
	[self didChangeValueForKey:@"selectedWhoWhats"];
	Attachment *a;
	NSEnumerator *e = [[email attachments] objectEnumerator];
	while (a = [e nextObject]) {
		if ([a parentWhoWhat] == nil)
			[a setParentWhoWhat:selectedWho != nil ? selectedWho : selectedWhat];
	}
}

- (void)alertDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	if (returnCode == NSAlertAlternateReturn) {
		// clicked create, so unset the what, and call create again
		[whatSearchResults deselectAll:self];
		[self create:self];
	}
}

- (IBAction)create:(id)sender {
	SObjectPermsWrapper *task = [SObjectPermsWrapper withDescribe:[sforce describeSObject:@"Task"] forUpdate:NO];
	[task setFieldValue:[NSString stringWithFormat:@"Email: %@", [email subject]] field:@"Subject"];
	[task setFieldValue:[email body] field:@"Description"];
	[task setFieldValue:[self closedTaskStatus] field:@"Status"];
	[task setFieldValue:@"Email" field:@"Type"];
	NSDate *date = [email date];
	if (date != nil) {
		NSCalendarDate *duedate = [date dateWithCalendarFormat:nil timeZone:nil];
		[task setFieldDateValue:duedate field:@"ActivityDate"];
	}
	ZKSObject *who = [self selectedWho];
	ZKSObject *what = [self selectedWhat];
	[task setFieldValue:[who id] field:@"WhoId"];
	if ([[who type] isEqualToString:@"Lead"] && (what != nil)) {
		NSAlert * a = [NSAlert alertWithMessageText:@"Can not create Email"
								defaultButton:@"Cancel Creation" 
								alternateButton:@"Create without setting \"Related to What\""
								otherButton:nil 
								informativeTextWithFormat:@"You can not create an email with a \"Related to What\" value when its \"Related to Who\" is a Lead"];
		[a beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:) contextInfo:nil]; 
		return;
	}  
	[task setFieldValue:[[self selectedWhat] id] field:@"WhatId"];
	ZKSaveResult *sr = [[sforce create:[NSArray arrayWithObject:[task sobject]]] objectAtIndex:0];
	if ([sr success]) {
		taskId = [[sr id] copy];
		[NSApp stopModal];
	} else { 
		NSAlert * a = [NSAlert alertWithMessageText:@"Unable to create email" defaultButton:@"OK" alternateButton:nil otherButton:nil informativeTextWithFormat:[sr message]];
		[a runModal];
	}
}

- (NSString *)escapeSosl:(NSString *)src {
	// from docs, these are all reserved
	NSArray *reserved = [NSArray arrayWithObjects:@"\\", @"&", @"|", @"!", @"{", @"}", @"[", @"]", @"^", @"~", @"*:", @":", @"'" ,@"\"", @"+", @"-", nil];
	NSMutableString *s = [NSMutableString stringWithString:src];
	NSString *r;
	NSEnumerator *e = [reserved objectEnumerator];
	while (r = [e nextObject]) 
		[s replaceOccurrencesOfString:r withString:[NSString stringWithFormat:@"\\%@", r] options:NSLiteralSearch range:NSMakeRange(0, [s length])];
	return s;
}

- (void)setWhoSearchResults:(NSArray *)res {
	if (res == whoSearchResults) return;
	[whoSearchResults release];
	whoSearchResults = [res retain];
}

- (BOOL)canSearchWho {
	return [self hasEntity:@"Contact"] || [self hasEntity:@"Lead"];
}

- (IBAction)searchWho:(id)sender {
	BOOL hasContacts = [self hasEntity:@"Contact"];
	BOOL hasLeads =    [self hasEntity:@"Lead"];
	NSMutableString *sosl = [NSMutableString stringWithFormat:@"FIND {%@} IN ALL FIELDS RETURNING ", [self escapeSosl:[self whoSearchText]]];
	if (hasLeads)
		[sosl appendFormat:@"Lead(%@)", WHO_FIELDS];
	if (hasContacts)
		[sosl appendFormat:@"%@Contact(%@)", hasLeads ? @", " : @"", WHO_FIELDS];
	@try {
		NSArray *res = [sforce search:sosl];
		[self setWhoSearchResults:res];
	}
	@catch (ZKSoapException *ex) {
		NSAlert * a = [NSAlert alertWithMessageText:@"Search Failed" defaultButton:@"OK" alternateButton:nil otherButton:nil informativeTextWithFormat:[ex reason]];
		[a runModal];
	}
}

- (NSString *)buildWhatSosl {
	NSMutableString *sosl = [NSMutableString stringWithFormat:@"FIND {%@*} IN ALL FIELDS RETURNING", [self escapeSosl:[self whatSearchText]]];
	NSMutableDictionary *sobject;
	BOOL first = YES;
	NSEnumerator *e = [[self whatObjectTypes] objectEnumerator];
	while (sobject = [e nextObject]) {
		if (![[sobject objectForKey:@"checked"] boolValue]) continue;
		ZKDescribeSObject *desc = [sforce describeSObject:[sobject objectForKey:@"type"]];
		[sosl appendFormat:@"%@ %@(Id", first ? @"" : @",", [desc name]];
		ZKDescribeField *f;
		NSEnumerator *fe = [[desc nameFields] objectEnumerator];
		while (f = [fe nextObject]) 
			[sosl appendFormat:@", %@", [f name]];
		f = [desc additionalDisplayField];
		if (f != nil) 
			[sosl appendFormat:@", %@", [f name]];
		[sosl appendFormat:@")"];
		first = NO;
	}
	return sosl;
}

- (void)setWhatSearchResultsData:(NSArray *)res {
	if (whatResultsTableSource == nil) {
		whatResultsTableSource = [[WhatSearchDataSource alloc] init];
		[whatSearchResults setDataSource:whatResultsTableSource];
	}
	[whatResultsTableSource setSforce:sforce];
	[whatResultsTableSource setResults:res];
	[whatSearchResults reloadData];
}

- (IBAction)searchWhat:(id)sender {
	[self saveCheckedWhats];
	NSString *sosl = [self buildWhatSosl];
	@try {
		NSArray *res = [sforce search:sosl];
		[self setWhatSearchResultsData:res];
	}
	@catch (ZKSoapException *ex) {
		NSAlert * a = [NSAlert alertWithMessageText:@"Search Failed" defaultButton:@"OK" alternateButton:nil otherButton:nil informativeTextWithFormat:[ex reason]];
		[a runModal];
	}
}

- (NSArray *)whoSearchResults {
	return whoSearchResults;
}

- (NSString *)whoSearchText {
	return whoSearchText;
}

- (void)setWhoSearchText:(NSString *)aWhoSearchText {
	aWhoSearchText = [aWhoSearchText copy];
	[whoSearchText release];
	whoSearchText = aWhoSearchText;
}

- (NSString *)whatSearchText {
	return whatSearchText;
}

- (void)setWhatSearchText:(NSString *)aWhatSearchText {
	aWhatSearchText = [aWhatSearchText copy];
	[whatSearchText release];
	whatSearchText = aWhatSearchText;
}

- (NSString *)contactFirstName {
	return contactFirstName;
}

- (void)setContactFirstName:(NSString *)aContactFirstName {
	aContactFirstName = [aContactFirstName copy];
	[contactFirstName release];
	contactFirstName = aContactFirstName;
}

- (NSString *)contactLastName {
	return contactLastName;
}

- (void)setContactLastName:(NSString *)aContactLastName {
	aContactLastName = [aContactLastName copy];
	[contactLastName release];
	contactLastName = aContactLastName;
}

- (NSString *)contactEmail {
	return contactEmail;
}

- (void)setContactEmail:(NSString *)aContactEmail {
	aContactEmail = [aContactEmail copy];
	[contactEmail release];
	contactEmail = aContactEmail;
}

- (NSString *)contactCompany {
	return contactCompany;
}

- (void)setContactCompany:(NSString *)aContactCompany {
	aContactCompany = [aContactCompany copy];
	[contactCompany release];
	contactCompany = aContactCompany;
}

- (NSString *)contactLeadStatus {
	return contactLeadStatus;
}

- (void)setContactLeadStatus:(NSString *)aContactLeadStatus {
	aContactLeadStatus = [aContactLeadStatus copy];
	[contactLeadStatus release];
	contactLeadStatus = aContactLeadStatus;
}

- (BOOL)createContactAllowed {
	return createContactAllowed;
}

- (void)setCreateContactAllowed:(BOOL)newCreateContactAllowed {
	createContactAllowed = newCreateContactAllowed;
}

- (BOOL)createLeadAllowed {
	return createLeadAllowed;
}

- (void)setCreateLeadAllowed:(BOOL)newCreateLeadAllowed {
	createLeadAllowed = newCreateLeadAllowed;
}

- (NSString *)emailSubject {
	return [email subject];
}

- (void)setEmailSubject:(NSString *)aEmailSubject {
	[email setSubject:aEmailSubject];
}

- (void)setCurrentPropertiesFromEmail {
	NSString *name = [email fromName];
	NSRange rng = [name rangeOfString:@" "];
	if (rng.location == NSNotFound) {
		[self setContactFirstName:nil];
		[self setContactLastName:name];
	} else {
		[self setContactFirstName:[name substringToIndex:rng.location]];
		[self setContactLastName:[name substringFromIndex:rng.location + rng.length]];
	}
	[self setContactEmail:[email fromAddr]];
	[self setContactCompany:@""];
	if ([self createLeadAllowed])
		[self setContactLeadStatus:[self defaultLeadStatus]];
	else
		[self setContactLeadStatus:@""];
}

- (void)resetState {
	[self setWhoSearchResults:nil];
	[self setWhatSearchResultsData:nil];
	[self setWhatSearchText:@""];
	[self setWhoSearchText:@""];
}

- (IBAction)showCreateContact:(id)sender {
	[self setCurrentPropertiesFromEmail];
	[NSApp beginSheet:createContactWindow modalForWindow:window modalDelegate:self didEndSelector:nil contextInfo:nil];
}

- (IBAction)cancelCreateContact:(id)sender {
	[NSApp endSheet:createContactWindow];
	[createContactWindow orderOut:sender];
}

- (IBAction)showCreateLead:(id)sender {
	[self setCurrentPropertiesFromEmail];
	[NSApp beginSheet:createLeadWindow modalForWindow:window modalDelegate:self didEndSelector:nil contextInfo:nil];
}

- (IBAction)cancelCreateLead:(id)sender {
	[NSApp endSheet:createLeadWindow];
	[createLeadWindow orderOut:sender];
}

- (NSString *)makeNotNull:(NSString *)s {
	 if (s == nil || [s length] == 0)
		return @" ";
	return s;
}

- (void)createNewSObjectItem:(BOOL)isLead window:(NSWindow *)sheetWindow {
	ZKSObject *n = [ZKSObject withType:isLead ? @"Lead" : @"Contact"];
	[n setFieldValue:[self makeNotNull:[self contactFirstName]] field:@"FirstName"];
	[n setFieldValue:[self makeNotNull:[self contactLastName]]  field:@"LastName"];
	[n setFieldValue:[self makeNotNull:[self contactEmail]]     field:@"Email"];
	if (isLead) {
		[n setFieldValue:[self makeNotNull:[self contactCompany]]   field:@"Company"];
		[n setFieldValue:[self makeNotNull:[self contactLeadStatus]] field:@"Status"];
	}
	ZKSaveResult *sr = [[sforce create:[NSArray arrayWithObject:n]] objectAtIndex:0];
	if ([sr success]) {
		[NSApp endSheet:sheetWindow];
		[sheetWindow orderOut:self];
		// query the record back from salesforce.com, pick up the compound name, plus anything else done server side
		n = [[[sforce query:[NSString stringWithFormat:@"select %@ from %@ where id='%@'", WHO_FIELDS, [n type], [sr id]]] records] objectAtIndex:0];
		// add info to list view, 
		NSMutableArray *newList = [NSMutableArray arrayWithArray:[self whoSearchResults]];
		[newList insertObject:n atIndex:0];
		[self setWhoSearchResults:newList];
		[whoSearchController setSelectionIndex:0];
	} else {
		NSAlert * a = [NSAlert alertWithMessageText:@"Create Failed" defaultButton:@"OK" alternateButton:nil otherButton:nil 
							   informativeTextWithFormat:[NSString stringWithFormat:@"%@ : %@", [sr statusCode], [sr message]]];
		[a runModal];
	}
}

- (IBAction)createContact:(id)sender {
	[self createNewSObjectItem:NO window:createContactWindow];
}

- (IBAction)createLead:(id)sender {
	[self createNewSObjectItem:YES window:createLeadWindow];
}

- (void)saveCheckedWhats {
	NSMutableArray *whats = [NSMutableArray array];
	NSDictionary *r;
	NSEnumerator *e = [[self whatObjectTypes] objectEnumerator];
	while (r = [e nextObject]) {
		if ([[r objectForKey:@"checked"] boolValue])
			[whats addObject:[r objectForKey:@"type"]];
	}
	[[NSUserDefaults standardUserDefaults] setObject:whats forKey:@"selectedWhats"];
}

- (NSNumber *)shouldWhatObjectBeChecked:(ZKDescribeSObject *)sobject {
	NSArray * defaultWhats = [[NSUserDefaults standardUserDefaults] objectForKey:@"selectedWhats"];
	bool checked = NO;
	if (defaultWhats == nil) 
		checked = ![sobject custom];
	else 
		checked = [defaultWhats containsObject:[sobject name]];
	return [NSNumber numberWithBool:checked];
}

- (NSArray *)whatObjectTypeDescribes {
	ZKDescribeSObject *desc = [sforce describeSObject:@"Task"];
	NSMutableArray *types = [NSMutableArray array];
	NSEnumerator *e = [[[desc fieldWithName:@"WhatId"] referenceTo] objectEnumerator];
	NSString *type;
	while (type = [e nextObject]) {
		// for sosl, you can't search products or solutions with everything else
		// they have to be done on there own, so for now, we'll just exclude them
		// from the list all together.
		if ([type isEqualToString:@"Product2"] || [type isEqualToString:@"Solution"]) continue;
		ZKDescribeSObject * rd = [sforce describeSObject:type];
		[types addObject:rd];
	}
	return types;
}

- (NSArray *)whatObjectTypes {
	if (whatObjectTypes != nil) return whatObjectTypes;
	NSArray *t = [self whatObjectTypeDescribes];
	NSMutableArray * types = [NSMutableArray array];
	NSEnumerator *e = [t objectEnumerator];
	ZKDescribeSObject *type;
	while (type = [e nextObject]) {
		NSMutableDictionary *t = [NSMutableDictionary dictionaryWithObjectsAndKeys:[self shouldWhatObjectBeChecked:type], @"checked", [type labelPlural], @"sobjectLabel", [type name], @"type", nil];
		[types addObject:t];
	}
	whatObjectTypes = [types retain];
	return whatObjectTypes;
}

- (IBAction)configureWhatSearchColumns:(id)sender {
	[NSApp beginSheet:whatSearchConfigWindow modalForWindow:window modalDelegate:nil didEndSelector:nil contextInfo:nil];
}

- (IBAction)closeWhatConfig:(id)sender {
	[NSApp endSheet:whatSearchConfigWindow];
	[whatSearchConfigWindow orderOut:sender];
}

- (BOOL)isCreateableObjectType:(NSString *)sobjectName {
	if (![self hasEntity:sobjectName]) return NO;
	return [[sforce describeSObject:sobjectName] createable];
}

- (void)initWhats:(id)sender {
	[self willChangeValueForKey:@"canSearchWho"];
	[self didChangeValueForKey:@"canSearchWho"];
	if (whatObjectTypes != nil) return;
	[self willChangeValueForKey:@"whatObjectTypes"];
	[whatObjectTypes release];
	whatObjectTypes = nil;
	[self didChangeValueForKey:@"whatObjectTypes"];
	[self willChangeValueForKey:@"leadStatus"];
	[leadStatus release];
	leadStatus = nil;
	[self didChangeValueForKey:@"leadStatus"];
	[self willChangeValueForKey:@"whatObjectTypeDescribes"];
	[self didChangeValueForKey:@"whatObjectTypeDescribes"];
}

- (NSString *)closedTaskStatus {
	if (closedTaskStatus != nil) return closedTaskStatus;
	ZKQueryResult *qr = [sforce query:@"select MasterLabel from TaskStatus where IsClosed=true"];
	if ([qr size] > 0) {
		ZKSObject *ts = [[qr records] objectAtIndex:0];
		closedTaskStatus = [[ts fieldValue:@"MasterLabel"] copy];
	}
	return closedTaskStatus;
}

- (NSArray *)leadStatus {
	if (leadStatus != nil) return leadStatus;
	if (sforce == nil) return nil;
	ZKQueryResult *qr = [sforce query:@"select MasterLabel, IsDefault from LeadStatus order by SortOrder"];
	NSMutableArray *ls = [NSMutableArray arrayWithCapacity:[qr size]];
	ZKSObject *s;
	NSEnumerator *e = [[qr records] objectEnumerator];
	while (s = [e nextObject]) {
		if ([s boolValue:@"IsDefault"])
			defaultLeadStatus = [[s fieldValue:@"MasterLabel"] copy];
		[ls addObject:[s fieldValue:@"MasterLabel"]];
	}
	leadStatus = [ls retain];
	return leadStatus;
}

- (NSString *)defaultLeadStatus {
	if (defaultLeadStatus == nil)
		[self leadStatus];
	return defaultLeadStatus;
}

- (void)setSforce:(ZKSforceClient *)sf {
	if (sf == sforce) return;
	[sforce release];
	sforce = [sf retain];
	[whatObjectTypes release];
	whatObjectTypes = nil;
	[closedTaskStatus release];
	closedTaskStatus = nil;
	[availableEntities release];
	availableEntities = nil;
	[leadStatus release];
	leadStatus = nil;
	[defaultLeadStatus release];
	defaultLeadStatus = nil;
	[selectedWho release];
	selectedWho = nil;
	[selectedWhat release];
	selectedWhat = nil;
	[self willChangeValueForKey:@"selectedWhoWhats"];
	[self didChangeValueForKey:@"selectedWhoWhats"];
	[self setCreateContactAllowed:[self isCreateableObjectType:@"Contact"]];
	[self setCreateLeadAllowed:[self isCreateableObjectType:@"Lead"]];	
}

- (NSString *)createActivity:(Email *)theEmail sforce:(ZKSforceClient *)sf {
	[self resetState];
	[self setSforce:sf];
	[self setEmail:theEmail];
	[self setWhoSearchText:[email fromAddr]];
	[NSApp activateIgnoringOtherApps:YES];
	NSTimer *t = [NSTimer timerWithTimeInterval:0.01 target:self selector:@selector(searchWho:) userInfo:nil repeats:NO];
	[[NSRunLoop currentRunLoop] addTimer:t forMode:NSModalPanelRunLoopMode];
	t = [NSTimer timerWithTimeInterval:0.02 target:self selector:@selector(initWhats:) userInfo:nil repeats:NO];
	[[NSRunLoop currentRunLoop] addTimer:t forMode:NSModalPanelRunLoopMode];
	[NSApp runModalForWindow:window];
	[window orderOut:self];
	// todo
	[self setEmail:nil];
	NSString *sfId = [taskId autorelease];
	taskId = nil;
	return sfId;
}

- (Email *)email {
	return email;
}

- (void)setEmail:(Email *)aValue {
	Email *oldEmail = email;
	email = [aValue retain];
	[oldEmail release];
}

@end
