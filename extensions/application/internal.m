#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <lauxlib.h>
#import "application.h"
#import "../window/window.h"

#define get_app(L, idx) *((AXUIElementRef*)luaL_checkudata(L, idx, "hs.application"))
#define nsobject_for_app(L, idx) [NSRunningApplication runningApplicationWithProcessIdentifier: pid_for_app(L, idx)]

static pid_t pid_for_app(lua_State* L, int idx) {
    get_app(L, idx); // type-checking
    lua_getuservalue(L, idx);
    lua_getfield(L, -1, "pid");
    pid_t p = lua_tonumber(L, -1);
    lua_pop(L, 2);
    return p;
}

static int application_eq(lua_State* L) {
    pid_t p1 = pid_for_app(L, 1);
    pid_t p2 = pid_for_app(L, 2);
    lua_pushboolean(L, (p1 == p2));
    return 1;
}

static int application_gc(lua_State* L) {
    AXUIElementRef app = get_app(L, 1);
    CFRelease(app);
    return 0;
}

/// hs.application.runningapplications() -> app[]
/// Constructor
/// Returns all running apps.
static int application_runningapplications(lua_State* L) {
    lua_newtable(L);
    int i = 1;
    
    for (NSRunningApplication* runningApp in [[NSWorkspace sharedWorkspace] runningApplications]) {
        new_application(L, [runningApp processIdentifier]);
        lua_rawseti(L, -2, i++);
    }
    
    return 1;
}

/// hs.application.applicationforpid(pid) -> app or nil
/// Constructor
/// Returns the running app for the given pid, if it exists.
static int application_applicationforpid(lua_State* L) {
    pid_t pid = luaL_checknumber(L, 1);
    
    NSRunningApplication* runningApp = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    
    if (runningApp)
        new_application(L, [runningApp processIdentifier]);
    else
        lua_pushnil(L);
    
    return 1;
}

/// hs.application.applicationsforbundleid(bundleid) -> app[]
/// Constructor
/// Returns any running apps that have the given bundleid.
static int application_applicationsforbundleid(lua_State* L) {
    const char* bundleid = luaL_checkstring(L, 1);
    NSString* bundleIdentifier = [NSString stringWithUTF8String:bundleid];
    
    lua_newtable(L);
    int i = 1;
    
    NSArray* runningApps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
    for (NSRunningApplication* runningApp in runningApps) {
        new_application(L, [runningApp processIdentifier]);
        lua_rawseti(L, -2, i++);
    }
    
    return 1;
}

/// hs.application:allwindows() -> window[]
/// Method
/// Returns all open windows owned by the given app.
static int application_allwindows(lua_State* L) {
    AXUIElementRef app = get_app(L, 1);
    
    lua_newtable(L);
    
    CFArrayRef windows;
    AXError result = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute, 0, 100, &windows);
    if (result == kAXErrorSuccess) {
        for (NSInteger i = 0; i < CFArrayGetCount(windows); i++) {
            AXUIElementRef win = CFArrayGetValueAtIndex(windows, i);
            CFRetain(win);
            
            new_window(L, win);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        CFRelease(windows);
    }
    
    return 1;
}

/// hs.application:mainwindow() -> window
/// Method
/// Returns the main window of the given app, or nil.
static int application_mainwindow(lua_State* L) {
    AXUIElementRef app = get_app(L, 1);
    
    CFTypeRef window;
    if (AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, &window) == kAXErrorSuccess) {
        new_window(L, window);
    }
    else {
        lua_pushnil(L);
    }
    
    return 1;
}

// a few private methods for app:activate(), defined in Lua

static int application__activate(lua_State* L) {
    NSRunningApplication* app = nsobject_for_app(L, 1);
    BOOL allwindows = lua_toboolean(L, 2);
    BOOL success = [app activateWithOptions:NSApplicationActivateIgnoringOtherApps | (allwindows ? NSApplicationActivateAllWindows : 0)];
    lua_pushboolean(L, success);
    return 1;
}

static int application__focusedwindow(lua_State* L) {
    AXUIElementRef app = get_app(L, 1);
    CFTypeRef window;
    if (AXUIElementCopyAttributeValue(app, (CFStringRef)NSAccessibilityFocusedWindowAttribute, &window) == kAXErrorSuccess) {
        new_window(L, window);
    }
    else {
        lua_pushnil(L);
    }
    return 1;
}

static int application_isunresponsive(lua_State* L) {
    // lol apple
    typedef int CGSConnectionID;
    CG_EXTERN CGSConnectionID CGSMainConnectionID(void);
    bool CGSEventIsAppUnresponsive(CGSConnectionID cid, const ProcessSerialNumber *psn);
    // srsly come on now
    
    pid_t pid = pid_for_app(L, 1);
    ProcessSerialNumber psn;
    GetProcessForPID(pid, &psn);
    
    CGSConnectionID conn = CGSMainConnectionID();
    bool is = CGSEventIsAppUnresponsive(conn, &psn);
    
    lua_pushboolean(L, is);
    return 1;
}

static int application__bringtofront(lua_State* L) {
    pid_t pid = pid_for_app(L, 1);
    BOOL allwindows = lua_toboolean(L, 2);
    ProcessSerialNumber psn;
    GetProcessForPID(pid, &psn);
    BOOL success = (SetFrontProcessWithOptions(&psn, allwindows ? 0 : kSetFrontProcessFrontWindowOnly) == noErr);
    lua_pushboolean(L, success);
    return 1;
}

/// hs.application:title() -> string
/// Method
/// Returns the localized name of the app (in UTF8).
static int application_title(lua_State* L) {
    NSRunningApplication* app = nsobject_for_app(L, 1);
    lua_pushstring(L, [[app localizedName] UTF8String]);
    return 1;
}

/// hs.application:bundleid() -> string
/// Method
/// Returns the bundle identifier of the app.
static int application_bundleid(lua_State* L) {
    NSRunningApplication* app = nsobject_for_app(L, 1);
    lua_pushstring(L, [[app bundleIdentifier] UTF8String]);
    return 1;
}

/// hs.application:unhide() -> success
/// Method
/// Unhides the app (and all its windows) if it's hidden.
static int application_unhide(lua_State* L) {
    AXUIElementRef app = get_app(L, 1);
    BOOL success = (AXUIElementSetAttributeValue(app, (CFStringRef)NSAccessibilityHiddenAttribute, kCFBooleanFalse) == kAXErrorSuccess);
    lua_pushboolean(L, success);
    return 1;
}

/// hs.application:hide() -> success
/// Method
/// Hides the app (and all its windows).
static int application_hide(lua_State* L) {
    AXUIElementRef app = get_app(L, 1);
    BOOL success = (AXUIElementSetAttributeValue(app, (CFStringRef)NSAccessibilityHiddenAttribute, kCFBooleanTrue) == kAXErrorSuccess);
    lua_pushboolean(L, success);
    return 1;
}

/// hs.application:kill()
/// Method
/// Tries to terminate the app.
static int application_kill(lua_State* L) {
    NSRunningApplication* app = nsobject_for_app(L, 1);
    
    [app terminate];
    return 0;
}

/// hs.application:kill9()
/// Method
/// Assuredly terminates the app.
static int application_kill9(lua_State* L) {
    NSRunningApplication* app = nsobject_for_app(L, 1);
    
    [app forceTerminate];
    return 0;
}

/// hs.application:ishidden() -> bool
/// Method
/// Returns whether the app is currently hidden.
static int application_ishidden(lua_State* L) {
    AXUIElementRef app = get_app(L, 1);
    
    CFTypeRef _isHidden;
    NSNumber* isHidden = @NO;
    if (AXUIElementCopyAttributeValue(app, (CFStringRef)NSAccessibilityHiddenAttribute, (CFTypeRef *)&_isHidden) == kAXErrorSuccess) {
        isHidden = CFBridgingRelease(_isHidden);
    }
    
    lua_pushboolean(L, [isHidden boolValue]);
    return 1;
}

/// hs.application:pid() -> number
/// Method
/// Returns the app's process identifier.
static int application_pid(lua_State* L) {
    lua_pushnumber(L, pid_for_app(L, 1));
    return 1;
}

/// hs.application:kind() -> number
/// Method
/// Returns 1 if the app is in the dock, 0 if not, and -1 if it can't even have GUI elements if it wanted to.
static int application_kind(lua_State* L) {
    NSRunningApplication* app = nsobject_for_app(L, 1);
    NSApplicationActivationPolicy pol = [app activationPolicy];
    
    int kind = 1;
    switch (pol) {
        case NSApplicationActivationPolicyAccessory:  kind =  0; break;
        case NSApplicationActivationPolicyProhibited: kind = -1; break;
        default: break;
    }
    
    lua_pushnumber(L, kind);
    return 1;
}

// Internal helper function to get an AXUIElementRef for a menu item in an app
AXUIElementRef _findmenuitem(lua_State* L, AXUIElementRef app, NSString *name) {
    AXUIElementRef foundItem = nil;
    AXUIElementRef menuBar;
    AXError error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute, (CFTypeRef *)&menuBar);
    if (error) {
        return nil;
    }

    CFIndex count = -1;
    error = AXUIElementGetAttributeValueCount(menuBar, kAXChildrenAttribute, &count);
    if (error) {
        CFRelease(menuBar);
        return nil;
    }

    CFArrayRef cf_children;
    error = AXUIElementCopyAttributeValues(menuBar, kAXChildrenAttribute, 0, count, &cf_children);
    if (error) {
        CFRelease(menuBar);
        return nil;
    }

    NSMutableArray *toCheck = [[NSMutableArray alloc] init];
    [toCheck addObjectsFromArray:(__bridge NSArray *)cf_children];

    int i = 5000; // This acts as a guard against this loop mysteriously running away
    while (i > 0) {
        i--;
        if ([toCheck count] == 0) {
            break;
        }

        // Get the first item in our queue and pop it out of the queue
        id firstObject = [toCheck firstObject];
        AXUIElementRef element = (__bridge AXUIElementRef)firstObject;
        [toCheck removeObjectIdenticalTo:firstObject];

        CFTypeRef cf_title;
        AXError error = AXUIElementCopyAttributeValue(element, kAXTitleAttribute, &cf_title);
        NSString *title = (__bridge_transfer NSString *)cf_title;

        // Check if this is a submenu, if so add its children to the toCheck array
        CFIndex childcount = -1;
        error = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute, &childcount);
        if (error) {
            NSLog(@"Got an error (%d) checking child count, skipping", (int)error);
            continue;
        }
        if (childcount > 0) {
            // This is a submenu. Collect its children into toCheck and continue iterating
            CFArrayRef cf_menuchildren;
            error = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute, 0, childcount, &cf_menuchildren);
            if (error) {
                NSLog(@"Got an error (%d) fetching menu children, skipping", (int)error);
                continue;
            }
            [toCheck addObjectsFromArray:(__bridge NSArray *)cf_menuchildren];
        } else if (childcount == 0) {
            // This doesn't seem to be a submenu, so see if it's a match
            if ([name isEqualToString:title]) {
                // It's a match. Store a reference to it and break out of the loop
                foundItem = element;
                break;
            }
        }
    }
    CFRelease(menuBar);

    if (i == 0) {
        NSLog(@"WARNING: _findmenuitem overflowed 5000 iteration guard. You have some crazy menus, or we have a bug!");
        lua_getglobal(L, "print");
        lua_pushstring(L, "WARNING: _findmenuitem() overflowed 5000 iteration guard. This is either a Hammerspoon bug, or you have some very deep menus");
        lua_call(L, 1, 0);
        return nil;
    }

    return foundItem;
}

/// hs.application:findmenuitem(name) -> table or nil
/// Method
/// Returns nil if the menu item 'name' cannot be found. If it does exist, returns a table with two keys:
///  enabled - whether the menu item can be selected/ticked. This will always be false if the application is not currently focussed
///  ticked - whether the menu item is ticked or not (obviously this value is meaningless for menu items that can't be ticked)
/// NOTE: This can only search for menu items that don't have children - i.e. you can't search for the name of a submenu
static int application_findmenuitem(lua_State* L) {
    AXError error;
    AXUIElementRef app = get_app(L, 1);
    NSString *name = [NSString stringWithUTF8String: luaL_checkstring(L, 2)];

    AXUIElementRef foundItem = _findmenuitem(L, app, name);
    if (!foundItem) {
        NSLog(@"Couldn't find %@", name);
        lua_pushnil(L);
        return 1;
    }

    CFTypeRef enabled;
    error = AXUIElementCopyAttributeValue(foundItem, kAXEnabledAttribute, &enabled);
    if (error) {
        NSLog(@"AXEnabled Error: %d", error);
        lua_pushnil(L);
        return 1;
    }
    CFTypeRef markchar;
    error = AXUIElementCopyAttributeValue(foundItem, kAXMenuItemMarkCharAttribute, &markchar);
    if (error && error != kAXErrorNoValue) {
        NSLog(@"AXMenuItemMarkChar: %d", error);
        lua_pushnil(L);
        return 1;
    }
    BOOL marked;
    if (error == kAXErrorNoValue) {
        // There's no value, which mean MarkChar is (null) and the menu item is not ticked
        marked = false;
    } else {
        // We might want to explicitly check for ✓ here, but this seems to be reliable enough for now
        marked = true;
    }

    lua_newtable(L);

    lua_pushstring(L, "enabled");
    lua_pushboolean(L, [(__bridge NSNumber *)enabled boolValue]);
    lua_settable(L, -3);

    lua_pushstring(L, "ticked");
    lua_pushboolean(L, marked);
    lua_settable(L, -3);

    return 1;
}

/// hs.application:selectmenuitem(name) -> true or nil
/// Method
/// Selects a menu item called 'name' if it exists in this application.
/// Depending on the type of menu item involved, this will either activate or tick/untick the menu item
/// Returns true if the menu item was found and selected, or nil if it wasn't (e.g. because the menu item couldn't be found)
static int application_selectmenuitem(lua_State* L) {
    AXUIElementRef app = get_app(L, 1);
    NSString *name = [NSString stringWithUTF8String: luaL_checkstring(L, 2)];

    AXUIElementRef foundItem = _findmenuitem(L, app, name);
    if (!foundItem) {
        NSLog(@"Couldn't find %@", name);
        lua_pushnil(L);
        return 1;
    }

    AXError error = AXUIElementPerformAction(foundItem, kAXPressAction);
    if (error) {
        NSLog(@"AXPress error: %d", (int)error);
        lua_pushnil(L);
        return 1;
    }

    lua_pushboolean(L, 1);
    return 1;
}

/// hs.application.launchorfocus(name) -> bool
/// Function
/// Launches the app with the given name, or activates it if it's already running.
/// Returns true if it launched or was already launched; otherwise false (presumably only if the app doesn't exist).
static int application_launchorfocus(lua_State* L) {
    NSString* name = [NSString stringWithUTF8String: luaL_checkstring(L, 1)];
    BOOL success = [[NSWorkspace sharedWorkspace] launchApplication: name];
    lua_pushboolean(L, success);
    return 1;
}

static const luaL_Reg applicationlib[] = {
    {"runningapplications", application_runningapplications},
    {"applicationforpid", application_applicationforpid},
    {"applicationsforbundleid", application_applicationsforbundleid},

    {"allwindows", application_allwindows},
    {"mainwindow", application_mainwindow},
    {"_activate", application__activate},
    {"_focusedwindow", application__focusedwindow},
    {"_bringtofront", application__bringtofront},
    {"title", application_title},
    {"bundleid", application_bundleid},
    {"unhide", application_unhide},
    {"hide", application_hide},
    {"kill", application_kill},
    {"kill9", application_kill9},
    {"ishidden", application_ishidden},
    {"pid", application_pid},
    {"isunresponsive", application_isunresponsive},
    {"kind", application_kind},
    {"findmenuitem", application_findmenuitem},
    {"selectmenuitem", application_selectmenuitem},
    {"launchorfocus", application_launchorfocus},

    {NULL, NULL}
};

int luaopen_hs_application_internal(lua_State* L) {
    luaL_newlib(L, applicationlib);
    
    if (luaL_newmetatable(L, "hs.application")) {
        lua_pushvalue(L, -2); // 'application' table
        lua_setfield(L, -2, "__index");
        
        lua_pushcfunction(L, application_eq);
        lua_setfield(L, -2, "__eq");
        
        lua_pushcfunction(L, application_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    
    return 1;
}
