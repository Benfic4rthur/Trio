import AppKit
import ApplicationServices
// Read-only AX hit-test grid. No document titles, labels, values or URLs.
let bundleID = "com.openai.codex"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { exit(2) }
let target = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(target,0.25)
let system = AXUIElementCreateSystemWide()
func value(_ element:AXUIElement,_ name:String)->CFTypeRef? {
 var value:CFTypeRef?
 guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else{return nil}
 return value
}
func summary(_ element:AXUIElement)->[String:Any] {
 var result:[String:Any]=[:]
 var pid:pid_t=0
 AXUIElementGetPid(element,&pid)
 result["pid"]=pid
 if let role=value(element,kAXRoleAttribute) as? String {result["role"]=role}
 if let subrole=value(element,kAXSubroleAttribute) as? String {result["subrole"]=subrole}
 if let p=value(element,kAXPositionAttribute), let s=value(element,kAXSizeAttribute),
    CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() {
  var point=CGPoint.zero,size=CGSize.zero
  if AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size) {
    result["frame"]=["x":point.x,"y":point.y,"width":size.width,"height":size.height]
  }
 }
 return result
}
var samples:[[String:Any]]=[]
var unique:[String:[String:Any]]=[:]
for y in stride(from:65,through:100,by:7) {
 for x in stride(from:85,through:200,by:8) {
  var record:[String:Any]=["x":x,"y":y]
  for (name,root) in [("application",target),("system",system)] {
   var hit:AXUIElement?
   let error=AXUIElementCopyElementAtPosition(root,Float(x),Float(y),&hit)
   if error == .success,let hit {
    let node=summary(hit)
    record[name]=node
    if let data=try? JSONSerialization.data(withJSONObject:node,options:[.sortedKeys]),let key=String(data:data,encoding:.utf8) {
     var aggregated=unique[key] ?? ["element":node,"sampleCount":0,"lookup":name]
     aggregated["sampleCount"]=(aggregated["sampleCount"] as? Int ?? 0)+1
     unique[key]=aggregated
    }
   } else {record[name+"Error"]=error.rawValue}
  }
  samples.append(record)
 }
}
let report:[String:Any]=["bundleID":bundleID,"pid":app.processIdentifier,"accessibilityTrusted":AXIsProcessTrusted(),
 "frontmostBundleID":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
 "generatedAt":ISO8601DateFormatter().string(from:Date()),"bounds":["xMin":85,"xMax":200,"yMin":65,"yMax":100],
 "uniqueElements":Array(unique.values),"samples":samples]
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
let args=ProcessInfo.processInfo.arguments
if args.count>1 {try data.write(to:URL(fileURLWithPath:args[1]),options:.atomic)}
print(String(data:data,encoding:.utf8)!)
