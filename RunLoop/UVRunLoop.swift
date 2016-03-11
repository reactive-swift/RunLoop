//===--- UVRunLoop.swift ----------------------------------------------===//
//Copyright (c) 2016 Daniel Leping (dileping)
//
//Licensed under the Apache License, Version 2.0 (the "License");
//you may not use this file except in compliance with the License.
//You may obtain a copy of the License at
//
//http://www.apache.org/licenses/LICENSE-2.0
//
//Unless required by applicable law or agreed to in writing, software
//distributed under the License is distributed on an "AS IS" BASIS,
//WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//See the License for the specific language governing permissions and
//limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Boilerplate
import UV
import CUV

public class UVRunLoop : RunnableRunLoopType, SettledType {
    typealias Semaphore = BlockingSemaphore
    
    //wrapping as containers to avoid copying
    private var _personalQueue:MutableAnyContainer<Array<SafeTask>>
    private var _commonQueue:MutableAnyContainer<Array<SafeTask>>
    private var _stop:MutableAnyContainer<Bool>
    
    private let _loop:Loop
    private let _wake:Async
    private let _caller:Prepare
    private let _semaphore:SemaphoreType
    
    private var _appartment:Thread? = nil
    
    public var isHome:Bool {
        get {
            guard let appartment = _appartment else {
                return false
            }
            return appartment == Thread.current
        }
    }
    
    private (set) public static var main:RunLoopType = UVRunLoop(loop: Loop.defaultLoop())
    
    private init(loop:Loop) {
        let personalQueue = MutableAnyContainer(Array<SafeTask>())
        let commonQueue = MutableAnyContainer(Array<SafeTask>())
        let stop = MutableAnyContainer(false)
        
        self._personalQueue = personalQueue
        self._commonQueue = commonQueue
        self._stop = stop
        
        let sema = BlockingSemaphore(value: 1)
        self._semaphore = sema
        
        //Yes, exactly. Fail in runtime if we can not create a loop
        self._loop = loop
        
        self._caller = try! Prepare(loop: _loop) { _ in
            while !personalQueue.content.isEmpty {
                let task = personalQueue.content.removeFirst()
                task()
                if stop.content {
                    break
                }
            }
        }
        
        //same with async
        self._wake = try! Async(loop: _loop) { _ in
            sema.wait()
            defer {
                sema.signal()
            }
            personalQueue.content.appendContentsOf(commonQueue.content)
            commonQueue.content.removeAll()
        }
    }
    
    public convenience required init() {
        self.init(loop: try! Loop())
    }
    
    deinit {
        _wake.close()
        _caller.close()
    }
    
    public func semaphore() -> SemaphoreType {
        return RunLoopSemaphore()
    }
    
    public func semaphore(value:Int) -> SemaphoreType {
        return RunLoopSemaphore(value: value)
    }
    
    public func execute(task:SafeTask) {
        if isHome {
            //here we are safe to be lock-less
            _personalQueue.content.append(task)
        } else {
            _semaphore.wait()
            defer {
                _semaphore.signal()
                _wake.send()
            }
            _commonQueue.content.append(task)
        }
    }
    
    public func execute(delay:Timeout, task:SafeTask) {
        let endTime = delay.timeSinceNow()
        execute {
            let timeout = Timeout(until: endTime)
            switch timeout {
            case .Immediate:
                self.execute(task)
            default:
                //yes, this is a runtime error
                let timer = try! Timer(loop: self._loop) { timer in
                    defer {
                        timer.close()
                    }
                    task()
                }
                //yes, this is a runtime error
                try! timer.start(timeout)
            }
        }
    }
    
    public var native:Any {
        get {
            return _loop
        }
    }
    
    /// returns true if timed out, false otherwise
    public func run(until:NSDate, once:Bool) -> Bool {
        let appartment = self._appartment
        defer {
            self._appartment = appartment
        }
        self._appartment = Thread.current
        
        defer {
            self._stop.content = false
        }
        //yes, fail if so. It's runtime error
        try! _caller.start()
        defer {
            //yes, fail if so. It's runtime error
            try! _caller.stop()
        }
        
        let mode = once ? UV_RUN_ONCE : UV_RUN_DEFAULT
        var timedout:Bool = false
        //yes, fail if so. It's runtime error
        let timer = try! Timer(loop: _loop) {_ in
            timedout = true
            self.stop()
        }
        //yes, fail if so. It's runtime error
        try! timer.start(Timeout(until: until))
        defer {
            timer.close()
        }
        while until.timeIntervalSinceNow >= 0 {
            _loop.run(mode)
            if once || self._stop.content {
                break
            }
        }
        return timedout
    }
    
    public func stop() {
        self._stop.content = true
        _loop.stop()
    }
    
    public func isEqualTo(other: NonStrictEquatable) -> Bool {
        guard let other = other as? UVRunLoop else {
            return false
        }
        return _loop == other._loop
    }
}