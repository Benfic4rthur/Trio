import AppKit
import ApplicationServices

// Owned-fixture-only geometry setup and read-only public identity evidence.
// No window titles or document contents. Never activates/operates Edge.
let args = ProcessInfo.processInfo.arguments
let bundleID = "com.allm4.TrioFixture"
func fail(_ message: String) -> Never { fputs(message+"\n",stderr); exit(2) }
func value(_ node:AXUIElement,_ name:String)->CFTypeRef? {var result:CFTypeRef?;guard AXUIElementCopyAttributeValue(node,name as CFString,&result) == .success else{return nil};return result}
func element(_ node:AXUIElement,_ name:String)->AXUIElement? {guard let value=value(node,name),CFGetTypeID(value)==AXUIElementGetTypeID() else{return nil};return(value as! AXUIElement)}
func frame(_ node:AXUIElement)->CGRect? {guard let p=value(node,kAXPositionAttribute),let s=value(node,kAXSizeAttribute),CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else{return nil};var point=CGPoint.zero,size=CGSize.zero;guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size) else{return nil};return CGRect(origin:point,size:size)}
func rect(_ r:CGRect)->[String:CGFloat] {["x":r.minX,"y":r.minY,"width":r.width,"height":r.height]}
func settle(_ seconds:Double){RunLoop.current.run(until:Date().addingTimeInterval(seconds))}
func equalFrame(_ a:CGRect,_ b:CGRect)->Bool {abs(a.minX-b.minX)<=2 && abs(a.minY-b.minY)<=2 && abs(a.width-b.width)<=2 && abs(a.height-b.height)<=2}
func pid(_ node:AXUIElement)->pid_t {var result:pid_t=0;AXUIElementGetPid(node,&result);return result}
func cgRows()->[[String:Any]] {let all=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? [];return all.enumerated().compactMap{order,row in guard let owner=row[kCGWindowOwnerPID as String] as? Int32,let id=row[kCGWindowNumber as String] as? Int,let layer=row[kCGWindowLayer as String] as? Int,let dict=row[kCGWindowBounds as String] as? NSDictionary,let r=CGRect(dictionaryRepresentation:dict) else{return nil};return["order":order,"pid":owner,"id":id,"layer":layer,"frame":rect(r)]}}
func rowFrame(_ row:[String:Any])->CGRect? {guard let r=row["frame"] as? [String:CGFloat],let x=r["x"],let y=r["y"],let w=r["width"],let h=r["height"] else{return nil};return CGRect(x:x,y:y,width:w,height:h)}
guard AXIsProcessTrusted() else{fail("Accessibility absent; no prompt requested")}
let apps=NSRunningApplication.runningApplications(withBundleIdentifier:bundleID)
guard apps.count==1,let app=apps.first,app.bundleURL?.resolvingSymlinksInPath().path=="/Users/arthurbenfica/Projetos/Trio/build/fixtures/TrioFixture.app" else{fail("Expected one owned fixture build")}
let expectedCount=args.firstIndex(of:"--window-count").flatMap{args.indices.contains($0+1) ? Int(args[$0+1]):nil} ?? 2
guard (2...15).contains(expectedCount) else{fail("Fixture proof supports 2 through 15 owned windows")}
let axApp=AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(axApp,0.2)
_ = app.unhide(); _ = app.activate(options:[.activateAllWindows]);settle(0.4)
if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
 let config=NSWorkspace.OpenConfiguration();config.activates=true;config.createsNewApplicationInstance=false;config.addsToRecentItems=false
 var done=false
 NSWorkspace.shared.openApplication(at:app.bundleURL!,configuration:config){_,_ in done=true}
 let deadline=Date().addingTimeInterval(3);while !done,Date()<deadline {settle(0.05)};settle(0.4)
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else{fail("Owned fixture could not become frontmost; no proof recorded")}

let readyDeadline=Date().addingTimeInterval(5)
while ((value(axApp,kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0)<expectedCount,Date()<readyDeadline {settle(0.05)}
guard let windows=value(axApp,kAXWindowsAttribute) as? [AXUIElement],windows.count==expectedCount,
      windows.allSatisfy({pid($0)==app.processIdentifier && value($0,kAXSubroleAttribute) as? String==kAXStandardWindowSubrole}) else{fail("Expected number of owned standard fixture windows is not ready")}
if args.contains("--same-bounds") {
 for window in windows {var p=CGPoint(x:320,y:260),s=CGSize(width:900,height:620);guard let pv=AXValueCreate(.cgPoint,&p),let sv=AXValueCreate(.cgSize,&s),AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,pv) == .success,AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,sv) == .success else{fail("Owned fixture setup failed")}}
 settle(0.45)
}
let trioPID=NSRunningApplication.runningApplications(withBundleIdentifier:"com.allm4.Trio").first?.processIdentifier
var snapshots:[[String:Any]]=[]
let focusSequence=args.contains("--all-windows") ? Array(windows.indices)+[0] : [0,1,0]
for index in focusSequence {
 guard NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else{fail("Fixture lost frontmost status during proof")}
 guard AXUIElementPerformAction(windows[index],kAXRaiseAction as CFString) == .success else{fail("Owned fixture raise failed")};settle(0.35)
 guard let focused=element(axApp,kAXFocusedWindowAttribute),let r=frame(focused) else{fail("Fixture focus unavailable")}
 let all=cgRows(),matches=all.filter{($0["pid"] as? Int32)==app.processIdentifier && ($0["layer"] as? Int)==0 && rowFrame($0).map{equalFrame($0,r)}==true}
 let names=[kAXCloseButtonAttribute,kAXMinimizeButtonAttribute,kAXZoomButtonAttribute]
 let hits:[[String:Any]]=names.map{name in guard let button=element(focused,name),let b=frame(button) else{return["attribute":name,"found":false]};var found:AXUIElement?;let error=AXUIElementCopyElementAtPosition(axApp,Float(b.midX),Float(b.midY),&found);var item:[String:Any]=["attribute":name,"frame":rect(b),"error":error.rawValue,"sameFocusedButton":found.map{CFEqual($0,button)} ?? false];if let found {item["hitPID"]=pid(found);item["hitRole"]=value(found,kAXRoleAttribute) as? String ?? "missing";item["hitSubrole"]=value(found,kAXSubroleAttribute) as? String ?? "missing"};return item}
 let focusStable=element(axApp,kAXFocusedWindowAttribute).map{CFEqual($0,focused)} ?? false
 let proof=hits.count==3 && hits.allSatisfy{$0["sameFocusedButton"] as? Bool==true} && focusStable
 let panels=all.filter{($0["pid"] as? Int32)==trioPID && ($0["layer"] as? Int)==3}
 let nativeRects=names.compactMap{element(focused,$0).flatMap{frame($0)}}
 let nativeUnion=nativeRects.dropFirst().reduce(nativeRects.first ?? .zero){$0.union($1)}
 let alignedPanels=panels.filter{rowFrame($0).map{r.contains($0) && $0.contains(nativeUnion)}==true}
 let isFront=NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier
 snapshots.append(["fixtureIsFrontmost":isFront,"trioPanelAlignedToFocusedControls":alignedPanels.count==1,"raisedFixtureIndex":index,"focusIsRaisedWindow":CFEqual(focused,windows[index]),"focusStableAfterHitTests":focusStable,"focusedFrame":rect(r),"matchingCGWindows":matches,"legacyUniqueMatcherAccepts":matches.count==1,"appRestrictedHitTests":hits,"appHitProofAcceptsTopmostCandidate":proof && !matches.isEmpty,"selectedTopmostCandidate":matches.first ?? [:],"trioPanels":panels])
}
let report:[String:Any]=["fixtureBundleID":bundleID,"fixturePID":app.processIdentifier,"trioPID":trioPID ?? 0,"expectedWindowCount":expectedCount,"generatedAt":ISO8601DateFormatter().string(from:Date()),"privateAPIs":false,"snapshots":snapshots]
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
let output=args.firstIndex(of:"--output").flatMap{args.indices.contains($0+1) ? args[$0+1]:nil} ?? "build/coincident-windows-probe.json"
try data.write(to:URL(fileURLWithPath:output),options:.atomic)
print(String(data:data,encoding:.utf8)!)
