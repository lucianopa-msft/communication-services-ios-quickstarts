//
//  ProviderDelegate.swift
//  iOSVideo
//
//  Created by Sanath Rao on 12/29/22.
//

import Foundation
import CallKit
import AzureCommunicationCommon
import AzureCommunicationCalling
import AVFAudio

enum CallKitErrors: String, Error {
    case invalidParticipant = "Could not get participants"
    case failedToConfigureAudioSession = "Failed to configure audio session"
    case unknownOutgoingCallType = "Unknown outgoing call type"
    case noIncomingCallFound = "No inoming call found to accept"
    case noActiveCallToEnd = "No active call found to end"
}

struct ActiveCallInfo {
    var completionHandler: (Error?) -> Void
}

struct OutInCallInfo {
    var participants: [CommunicationIdentifier]?
    var meetingLocator: JoinMeetingLocator?
    var options: Any?
    var completionHandler: (Call?, Error?) -> Void
}

final class ProviderDelegateImpl : NSObject, CXProviderDelegate {
    private var callKitHelper: CallKitHelper
    private var callAgent: CallAgent?
    
    init(with callKitHelper: CallKitHelper, callAgent: CallAgent?) {
        self.callKitHelper = callKitHelper
        self.callAgent = callAgent
    }

    func setCallAgent(callAgent: CallAgent) {
        self.callAgent = callAgent
    }

    private func configureAudioSession() -> Error? {
        let audioSession: AVAudioSession = AVAudioSession.sharedInstance()

        var configError: Error?
        do {
            try audioSession.setCategory(.playAndRecord)
        } catch {
            configError = error
        }

        return configError
    }

    func providerDidReset(_ provider: CXProvider) {
        
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task {
            let error = configureAudioSession()
            
            // this can be nil and its ok because this can also directly come from CallKit
            let outInCallInfo = await callKitHelper.getOutInCallInfo(transactionId: action.uuid)
            
            if error != nil {
                action.fail()
                outInCallInfo?.completionHandler(nil, error)
                return
            }

            let completionBlock : ((Call?, Error?) -> Void) = { (call, error) in
                
                if error == nil {
                    action.fulfill()
                    Task {
                        await self.callKitHelper.addActiveCall(callId: action.callUUID.uuidString,
                                                               call: call!)
                    }
                } else {
                    action.fail()
                }
                outInCallInfo?.completionHandler(call, error)
                Task {
                    await self.callKitHelper.removeOutInCallInfo(transactionId: action.uuid)
                }
            }

            if let incomingCall = await callKitHelper.getIncomingCall(callId: action.callUUID),
               let acceptCallOptions = outInCallInfo?.options as? AcceptCallOptions {
                incomingCall.accept(options: acceptCallOptions, completionHandler: completionBlock)
                return
            }
            
            let dispatchSemaphore = await self.callKitHelper.setAndGetSemaphore()
            DispatchQueue.global().async {
                _ = dispatchSemaphore.wait(timeout: DispatchTime(uptimeNanoseconds: 10 * NSEC_PER_SEC))
                Task {
                    if let incomingCall = await self.callKitHelper.getIncomingCall(callId: action.callUUID),
                       let acceptCallOptions = outInCallInfo?.options as? AcceptCallOptions {
                        incomingCall.accept(options: acceptCallOptions, completionHandler: completionBlock)
                    } else {
                        completionBlock(nil, CallKitErrors.noIncomingCallFound)
                    }
                }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task {
            guard let activeCall = await self.callKitHelper.getActiveCall(callId: action.callUUID.uuidString) else {
                return
            }

            let activCallInfo = await self.callKitHelper.getActiveCallInfo(transactionId: action.uuid.uuidString)
            activeCall.hangUp(options: nil) { error in
                // Its ok if hangup fails because we maybe hanging up already hanged up call
                action.fulfill()
                activCallInfo?.completionHandler(error)
                Task {
                    await self.callKitHelper.removeActiveCall(callId: activeCall.id)
                    await self.callKitHelper.removeActiveCallInfo(transactionId: action.uuid.uuidString)
                }
            }
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task {
            guard let activeCall = await self.callKitHelper.getActiveCall() else {
                print("No active calls found !!")
                return
            }
            
            activeCall.unmute { error in
                if error == nil {
                    print("Successfully unmuted mic")
                    activeCall.speaker(mute: false) { error in
                        if error == nil {
                            print("Successfully unmuted speaker")
                        }
                    }
                }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("Perform CXStartCallAction")
        Task {
            // This will be raised by CallKit always after raising a transaction
            // Which means an API call will have to happen to reach here
            guard let outInCallInfo = await callKitHelper.getOutInCallInfo(transactionId: action.uuid) else {
                return
            }
            
            let error = configureAudioSession()
            
            let completionBlock : ((Call?, Error?) -> Void) = { (call, error) in
                
                if error == nil {
                    action.fulfill()
                    Task {
                        await self.callKitHelper.addActiveCall(callId: action.callUUID.uuidString,
                                                               call: call!)
                    }
                } else {
                    action.fail()
                }
                outInCallInfo.completionHandler(call, error)
                Task {
                    await self.callKitHelper.removeOutInCallInfo(transactionId: action.uuid)
                }
            }

            if error == nil {
                // Start by muting both speaker and mic audio and unmute when
                // didActivateAudioSession callback is recieved.
                let mutedAudioOptions = AudioOptions()
                mutedAudioOptions.speakerMuted = true
                mutedAudioOptions.muted = true
                
                if let participants = outInCallInfo.participants {
                    let copyStartCallOptions = StartCallOptions()
                    if let startCallOptions = outInCallInfo.options as? StartCallOptions {
                        copyStartCallOptions.videoOptions = startCallOptions.videoOptions
                    }
                    
                    copyStartCallOptions.audioOptions = mutedAudioOptions
                    callAgent!.startCall(participants: participants,
                                        options: copyStartCallOptions,
                                        completionHandler: completionBlock)
                } else if let meetingLocator = outInCallInfo.meetingLocator {
                    let copyJoinCallOptions = JoinCallOptions()
                    if let joinCallOptions = outInCallInfo.options as? JoinCallOptions {
                        copyJoinCallOptions.videoOptions = joinCallOptions.videoOptions
                    }
                    
                    copyJoinCallOptions.audioOptions = mutedAudioOptions
                    callAgent!.join(with: meetingLocator,
                                   joinCallOptions: copyJoinCallOptions,
                                   completionHandler: completionBlock)
                } else {
                    completionBlock(nil, CallKitErrors.unknownOutgoingCallType)
                }
            } else {
                completionBlock(nil, error)
            }
        }
    }
}

class CallKitIncomingCallReporter {
    var cxProvider: CXProvider
    init(cxProvider: CXProvider) {
        self.cxProvider = cxProvider
    }
    
    private func createCallUpdate(isVideoEnabled: Bool, localizedCallerName: String, handle: CXHandle) -> CXCallUpdate {
        let callUpdate = CXCallUpdate()
        callUpdate.hasVideo = isVideoEnabled
        callUpdate.supportsHolding = true
        callUpdate.supportsDTMF = true
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.localizedCallerName = localizedCallerName
        callUpdate.remoteHandle = handle
        return callUpdate
    }

    func reportIncomingCall(callId: String,
                            callerInfo: CallerInfo,
                            videoEnabled: Bool,
                            completionHandler: @escaping (Error?) -> Void)
    {
        reportIncomingCall(callId: callId,
                           caller: callerInfo.identifier,
                           callerDisplayName: callerInfo.displayName,
                           videoEnabled: videoEnabled, completionHandler: completionHandler)
    }

    func reportIncomingCall(callId: String,
                            caller:CommunicationIdentifier,
                            callerDisplayName: String,
                            videoEnabled: Bool,
                            completionHandler: @escaping (Error?) -> Void)
    {
        let handleType: CXHandle.HandleType = caller .isKind(of: PhoneNumberIdentifier.self) ? .phoneNumber : .generic
        let handle = CXHandle(type: handleType, value: caller.rawId)
        let callUpdate = createCallUpdate(isVideoEnabled: videoEnabled, localizedCallerName: callerDisplayName, handle: handle)
        self.cxProvider.reportNewIncomingCall(with: UUID(uuidString: callId.uppercased())!, update: callUpdate) { error in
            completionHandler(error)
        }
    }
}


actor CallKitHelper {
    private var callController = CXCallController()
    private var outInCallInfoMap: [String: OutInCallInfo] = [:]
    private var incomingCallMap: [String: IncomingCall] = [:]
    private var incomingCallSemaphore: DispatchSemaphore?
    private var activeCalls: [String : Call] = [:]
    private var cxProvider: CXProvider
    private var updatedCallIdMap: [String:String] = [:]
    private var activeCallInfos: [String: ActiveCallInfo] = [:]

    func getActiveCallInfo(transactionId: String) -> ActiveCallInfo? {
        return activeCallInfos[transactionId.uppercased()]
    }

    func removeActiveCallInfo(transactionId: String) {
        activeCallInfos.removeValue(forKey: transactionId.uppercased())
    }

    private func onIdChanged(newId: String, oldId: String) {
        if newId != oldId {
            updatedCallIdMap[newId.uppercased()] = oldId.uppercased()
        }
    }
    
    init(cxProvider: CXProvider) {
        self.cxProvider = cxProvider
    }

    func setAndGetSemaphore() -> DispatchSemaphore {
        self.incomingCallSemaphore = DispatchSemaphore(value: 0)
        return self.incomingCallSemaphore!
    }
    
    func setIncomingCallSemaphore(semaphore: DispatchSemaphore) {
        self.incomingCallSemaphore = semaphore
    }

    func addIncomingCall(incomingCall: IncomingCall) {
        incomingCallMap[incomingCall.id] = incomingCall
        self.incomingCallSemaphore?.signal()
    }
    
    func removeIncomingCall(callId: String) {
        incomingCallMap.removeValue(forKey: callId)
        self.incomingCallSemaphore?.signal()
    }
    
    func getIncomingCall(callId: UUID) -> IncomingCall? {
        return incomingCallMap[callId.uuidString.uppercased()]
    }

    func addActiveCall(callId: String, call: Call) {
        onIdChanged(newId: call.id.uppercased(), oldId: callId.uppercased())
        activeCalls[callId] = call
    }

    func removeActiveCall(callId: String) {
        let finalCallId = getReportedCallIdToCallKit(callId: callId)
        activeCalls.removeValue(forKey: finalCallId.uppercased())
    }

    func getActiveCall(callId: String) -> Call? {
        let finalCallId = getReportedCallIdToCallKit(callId: callId)
        return activeCalls[finalCallId]
    }

    func getActiveCall() -> Call? {
        // We only allow one active call at a time
        return activeCalls.first?.value
    }

    func removeOutInCallInfo(transactionId: UUID) {
        outInCallInfoMap.removeValue(forKey: transactionId.uuidString.uppercased())
    }

    func getOutInCallInfo(transactionId: UUID) -> OutInCallInfo? {
        return outInCallInfoMap[transactionId.uuidString.uppercased()]
    }

    private func isVideoOn(options: Any?) -> Bool
    {
        guard let optionsUnwrapped = options else {
            return false
        }
        
        var videoOptions: VideoOptions?
        if let joinOptions = optionsUnwrapped as? JoinCallOptions {
            videoOptions = joinOptions.videoOptions
        } else if let acceptOptions = optionsUnwrapped as? AcceptCallOptions {
            videoOptions = acceptOptions.videoOptions
        } else if let startOptions = optionsUnwrapped as? StartCallOptions {
            videoOptions = startOptions.videoOptions
        }
        
        guard let videoOptionsUnwrapped = videoOptions else {
            return false
        }
        
        return videoOptionsUnwrapped.localVideoStreams.count > 0
    }

    private func transactOutInCallWithCallKit(action: CXAction, outInCallInfo: OutInCallInfo) {
        callController.requestTransaction(with: action) { [self] error in
            if error != nil {
                outInCallInfo.completionHandler(nil, error)
            } else {
                outInCallInfoMap[action.uuid.uuidString.uppercased()] = outInCallInfo
            }
        }
    }
    
    private func transactWithCallKit(action: CXAction, activeCallInfo: ActiveCallInfo) {
        callController.requestTransaction(with: action) { error in
            if error != nil {
                activeCallInfo.completionHandler(error)
            } else {
                self.activeCallInfos[action.uuid.uuidString.uppercased()] = activeCallInfo
            }
        }
    }

    private func getReportedCallIdToCallKit(callId: String) -> String {
        var finalCallId : String
        if let newCallId = self.updatedCallIdMap[callId.uppercased()] {
            finalCallId = newCallId
        } else {
            finalCallId = callId.uppercased()
        }
        
        return finalCallId
    }

    func acceptCall(callId: String,
                    options: AcceptCallOptions?,
                    completionHandler: @escaping (Call?, Error?) -> Void)
    
    {
        let callId = UUID(uuidString: callId.uppercased())!
        let answerCallAction = CXAnswerCallAction(call: callId)
        let outInCallInfo = OutInCallInfo(participants: nil,
                                          options: options,
                                          completionHandler: completionHandler)
        transactOutInCallWithCallKit(action: answerCallAction, outInCallInfo: outInCallInfo)
    }

    func reportOutgoingCall(call: Call) {
        if call.direction != .outgoing {
            return
        }

        let finalCallId = getReportedCallIdToCallKit(callId: call.id)

        if call.state == .connected {
            self.cxProvider.reportOutgoingCall(with: UUID(uuidString: finalCallId.uppercased())! , connectedAt: nil)
        } else if call.state != .connecting {
            self.cxProvider.reportOutgoingCall(with: UUID(uuidString: finalCallId.uppercased())! , startedConnectingAt: nil)
        }
    }

    func endCall(callId: String, completionHandler: @escaping (Error?) -> Void) {
        let finalCallId = getReportedCallIdToCallKit(callId: callId)
        let endCallAction = CXEndCallAction(call: UUID(uuidString: finalCallId.uppercased())!)
        transactWithCallKit(action: endCallAction, activeCallInfo: ActiveCallInfo(completionHandler: completionHandler))
    }

    func placeCall(participants: [CommunicationIdentifier]?,
                   callerDisplayName: String,
                   meetingLocator: JoinMeetingLocator?,
                   options: Any?,
                   completionHandler: @escaping (Call?, Error?) -> Void)
    {
        let callId = UUID()
        
        var compressedParticipant: String = ""
        var handleType: CXHandle.HandleType = .generic

        if let participants = participants {
            if participants.count == 1 {
                if participants.first is PhoneNumberIdentifier {
                    handleType = .phoneNumber
                }
                compressedParticipant = participants.first!.rawId
            } else {
                for participant in participants {
                    handleType = participant is PhoneNumberIdentifier ? .phoneNumber : .generic
                    compressedParticipant.append(participant.rawId + ";")
                }
            }
        } else if let meetingLoc = meetingLocator as? GroupCallLocator {
            compressedParticipant = meetingLoc.groupId.uuidString
        }

        #if BETA
        if let meetingLoc = meetingLocator as? TeamsMeetingLinkLocator {
            compressedParticipant = meetingLoc.meetingLink
        } else if let meetingLoc = meetingLocator as? TeamsMeetingCoordinatesLocator {
            compressedParticipant = meetingLoc.threadId
        }
        #endif
        
        if (compressedParticipant == "") {
            completionHandler(nil, CallKitErrors.invalidParticipant)
            return
        }

        let handle = CXHandle(type: handleType, value: compressedParticipant)
        let startCallAction = CXStartCallAction(call: callId, handle: handle)
        startCallAction.isVideo = isVideoOn(options: options)
        startCallAction.contactIdentifier = callerDisplayName
        
        transactOutInCallWithCallKit(action: startCallAction,
                                     outInCallInfo: OutInCallInfo(participants: participants,
                                                                  meetingLocator: meetingLocator,
                                                                  options: options, completionHandler: completionHandler))
    }
    
}
