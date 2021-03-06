//
//  XibProcessor.swift
//  Xib2ObjC_Server
//
//  Created by 张楠[产品技术中心] on 2018/5/28.
//

import Foundation
import SWXMLHash

public class XibProcessor: NSObject {
    private var _xml: XMLIndexer?
    private var _data: Data
    private var _filename: String
    private var _output: String
    private var _objects: [String: [String: String]]
    private var _hierarchys: [String: [String]]
    private var _constraints: [String: [XMLIndexer]]
    private lazy var xmlTmpPath: String = {
        let path = Bundle.main.bundlePath
        return path + "/tmpXML"
    }()
    private let _cellClassNames = ["UITableViewCell", "UICollectionViewCell"]
    private lazy var outputPath: String = {
        let path = NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true)[0]
        return path + "/Xib2ObjC_GeneratedViews"
    }()
    
    public var input: String {
        get {
            return _filename
        }
        set(newValue) {
            _filename = newValue
        }
    }
    public var output: String {
        get {
            return _output
        }
    }
    
    public var viewFile: ViewFile
    
    override public init() {
        _data = Data()
        _filename = ""
        _output = ""
        _objects = [String: [String: String]]()
        _hierarchys = [String: [String]]()
        _constraints = [String: [XMLIndexer]]()
        viewFile = ViewFile(name: "", inheritName: "", constructor: "")
    }
    
    // MARK: - Private Methods
    private func getDictionaryFromXib() throws {
        let fileMgr = FileManager.default
        
        if !fileMgr.fileExists(atPath: _filename) {
            throw Xib2ObjCError.xibFileNotExist("no such file: \(_filename).")
        }
        
        if fileMgr.fileExists(atPath: xmlTmpPath) {
            try? fileMgr.removeItem(atPath: xmlTmpPath)
        }
        
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = ["ibtool", _filename, "--write", xmlTmpPath];
        p.launch()
        p.waitUntilExit()
        
        if !p.isRunning {
            let status = p.terminationStatus
            if status == 0 {
                // task succeeded.
                if fileMgr.fileExists(atPath: xmlTmpPath) {
                    _data = fileMgr.contents(atPath: xmlTmpPath)!
                    let text = inputAsText()
                    _xml = SWXMLHash.parse(text)
                }
            } else {
                // task failed.
            }
        }
    }
    
    private func enumerate(_ indexer: XMLIndexer, level: Int) throws {
        
        let processor = Processor.processor(elementName: indexer.element!.name)
        guard let p = processor else {
            throw Xib2ObjCError.unknownXibObject("can't parse xib object: \(indexer.element!.name).")
        }
        
        var obj = p.process(indexer: indexer)
        if level == 0 {
            viewFile = ViewFile.getViewFile(klass: obj["class"]!, xibPath: _filename)
            obj["instanceName"] = "self"
        }
        
        var identifier = indexer.element!.idString
        var subviewsIndexer = indexer["subviews"]
        var constraintsIndexer = indexer["constraints"]
        if indexer.element!.name == "tableViewCell" {
            subviewsIndexer = indexer["tableViewCellContentView"]["subviews"]
            constraintsIndexer = indexer["tableViewCellContentView"]["constraints"]
            identifier = indexer["tableViewCellContentView"].element!.idString
        } else if indexer.element!.name == "collectionViewCell" {
            subviewsIndexer = indexer["view"]["subviews"]
        }
        
        _objects[identifier] = obj
        
        if constraintsIndexer.element != nil {
            _constraints[identifier] = constraintsIndexer.children
        }
        
        var subObjs = [String]()
        if (subviewsIndexer.element != nil) {
            let subviews = subviewsIndexer.children
            try subviews.forEach({ (indexer) in
                subObjs.append(indexer.element!.idString)
                try enumerate(indexer, level: level+1)
            })
        }
        
        if subObjs.count > 0 {
            _hierarchys[identifier] = subObjs
        }
    }
    
    // MARK: - Public Methods
    public func process() throws -> String {
        try getDictionaryFromXib()
        
        guard let xml = _xml else {
            throw Xib2ObjCError.parseXibToXmlFailed("can't parse xib to xml.")
        }
        
        // get all objects
        let root = xml["document"]["objects"].filterChildren { _, index in index > 1 }.children[0]
        
        if let guide = root["viewLayoutGuide"].element, guide.isSafeArea {
            throw Xib2ObjCError.notSupportSafeArea("please uncheck \"Use Safe Area Layout Guides\" in your xib.")
        }
        
        try enumerate(root, level: 0)
        
        //construct output string
        for (_, object) in _objects.reversed() {
            
            let instanceName = object["instanceName"]!
            
            let klass = object["class"]!
            let constructor = object["constructor"]!
            if instanceName != "self" {
                if object["userLabel"] != nil {
                    _output.append("    \(instanceName) = \(constructor);\n")
                } else {
                    _output.append("    \(klass) *\(instanceName) = \(constructor);\n")
                }
            }
            
            object.sorted(by: {$0.0 < $1.0}).filter{(key, _) in !["instanceName", "class", "constructor", "userLabel"].contains(key) && !key.hasPrefix("__method__") }.forEach({ (key, value) in
                _output.append("    \(instanceName).\(key) = \(value);\n")
            })
            
            object.sorted(by: {$0.0 < $1.0}).filter{(key, _) in key.hasPrefix("__method__")}.forEach({ (_, value) in
                _output.append("    [\(instanceName) \(value)];\n")
            })
            
            _output.append("\n")
        }
        
        _hierarchys.forEach { (superviewId, subviewsId) in
            var superView = _objects[superviewId]!["instanceName"]!
            if _cellClassNames.contains(_objects[superviewId]!["class"]!) {
                superView = superView + ".contentView"
            }
            subviewsId.forEach({ (subviewId) in
                let subInstanceName = _objects[subviewId]!["instanceName"]!
                _output.append("    [\(superView) addSubview:\(subInstanceName)];\n")
            })
        }
        
        _output.append("\n")
        
        _hierarchys.forEach { (superviewId, subviewsId) in
            let superConstraints = _constraints[superviewId] ?? []
            
            subviewsId.forEach({ (subviewId) in
                var allMasonryConstraints = [String]() //放与该view相关的constraints
               
                let subInstanceName = _objects[subviewId]!["instanceName"]!
               
                let subConstraints = _constraints[subviewId] ?? []
               
                subConstraints.filter{ indexer in
                    indexer.element!.firstItemIdString == "" && indexer.element!.secondItemIdString == ""
                }.forEach({ (indexer) in
                    let constraint = "make.\(indexer.element!.firstAttributeString).mas_equalTo(\(indexer.element!.constantString))"
                    allMasonryConstraints.append(constraint)
                })
                
                superConstraints.filter{ indexer in indexer.element!.firstItemIdString == subviewId }.forEach({ (indexer) in
                    let secondItem = indexer.element!.secondItemIdString
                    var secondInstanceName = _objects[secondItem]!["instanceName"]!
                    if _cellClassNames.contains(_objects[superviewId]!["class"]!) {
                        secondInstanceName = secondInstanceName + ".contentView"
                    }

                    var constraint = "make.\(indexer.element!.firstAttributeString).\(indexer.element!.relationString)(\(secondInstanceName).mas_\(indexer.element!.secondAttributeString))"
                    let constant = indexer.element!.constantString
                    if constant != "" {
                        constraint = constraint + ".offset(\(constant))"
                    }
                    allMasonryConstraints.append(constraint)
                })
                
                var superInstanceName = _objects[superviewId]!["instanceName"]!
                if _cellClassNames.contains(_objects[superviewId]!["class"]!) {
                    superInstanceName = superInstanceName + ".contentView"
                }
                superConstraints.filter{ indexer in indexer.element!.firstItemIdString == "" && indexer.element!.secondItemIdString == subviewId }.forEach({ (indexer) in
                    var constraint = "make.\(indexer.element!.secondAttributeString).\(indexer.element!.relationString)(\(superInstanceName).mas_\(indexer.element!.firstAttributeString))"
                    let constant = indexer.element!.constantString
                    if constant != "" {
                        constraint = constraint + ".offset(-\(constant))"
                    }
                    allMasonryConstraints.append(constraint)
                })
                
                if allMasonryConstraints.count > 0 {
                    _output.append("    [\(subInstanceName) mas_makeConstraints:^(MASConstraintMaker *make) {\n")
                    allMasonryConstraints.forEach({ (constraint) in
                        _output.append("        " + constraint + ";\n")
                    })
                    _output.append("    }];\n\n")
                }
            })
        }
        
        try generateFiles()
        
        return outputPath + "/\(viewFile.name)"
    }
    
    private func getProperties() -> String {
        var propertyString = ""
        _objects.forEach { (_, object) in
            if let userLabel = object["userLabel"] {
                propertyString += "@property (nonatomic, strong) \(object["class"]!) *\(userLabel);\n"
            }
        }
        return propertyString
    }
    
    private func generateFiles() throws {
        var viewHFileString = viewFileFormatDict["ViewHFileString"]!
        viewHFileString = viewHFileString.replacingOccurrences(of: "[View-Name]", with: viewFile.name)
        viewHFileString = viewHFileString.replacingOccurrences(of: "[Inherit-Name]", with: viewFile.inheritName)
        viewHFileString = viewHFileString.replacingOccurrences(of: "[Author]", with: projectInfo.author)
        viewHFileString = viewHFileString.replacingOccurrences(of: "[Date]", with: projectInfo.dateString)
        viewHFileString = viewHFileString.replacingOccurrences(of: "[Year]", with: projectInfo.yearString)
        
        var viewMFileString = viewFileFormatDict["ViewMFileString"]!
        viewMFileString = viewMFileString.replacingOccurrences(of: "[View-Name]", with: viewFile.name)
        viewMFileString = viewMFileString.replacingOccurrences(of: "[Constructor]", with: viewFile.constructor)
        viewMFileString = viewMFileString.replacingOccurrences(of: "[Date]", with: projectInfo.dateString)
        viewMFileString = viewMFileString.replacingOccurrences(of: "[Year]", with: projectInfo.yearString)
        viewMFileString = viewMFileString.replacingOccurrences(of: "[Author]", with: projectInfo.author)
        viewMFileString = viewMFileString.replacingOccurrences(of: "[UI-Layout]", with: _output)
        viewMFileString = viewMFileString.replacingOccurrences(of: "[Property]", with: getProperties())
        
        let fileMgr = FileManager.default
        if !fileMgr.fileExists(atPath: outputPath) {
            do {
                try fileMgr.createDirectory(atPath: outputPath, withIntermediateDirectories: false, attributes: nil)
            } catch {
                throw Xib2ObjCError.createOutputDirFailed("can't create output directory: \(outputPath).")
            }
        }
        let headerFilePath = outputPath + "/\(viewFile.name).h"
        let mFilePath = outputPath + "/\(viewFile.name).m"
        var data = viewHFileString.data(using: String.Encoding.utf8)
        fileMgr.createFile(atPath: headerFilePath, contents: data, attributes: nil)
        data = viewMFileString.data(using: String.Encoding.utf8)
        fileMgr.createFile(atPath: mFilePath, contents: data, attributes: nil)
        
        openFile(outputPath)
    }
    
    public func inputAsText() -> String {
        return String(data: _data, encoding: String.Encoding.utf8)!
    }
    
    private func openFile(_ filePath: String) {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["open", filePath]
        process.launch()
    }
}
