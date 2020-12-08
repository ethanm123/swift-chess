//
//  Board+Game.swift
//
//  Created by Douglas Pedley on 1/6/19.
//  Copyright © 2019 d0. All rights reserved.
//

import Foundation

extension Chess.Board {
    internal func lastEnPassantPosition() -> Chess.Position? {
        guard let sideEffect = lastMove?.sideEffect else { return nil }
        switch sideEffect {
        case Chess.Move.SideEffect.enPassantInvade(let territory, _):
            return territory
        default:
            return nil
        }
    }
    internal func findKing(_ side: Chess.Side) -> Chess.Square {
        guard let square = findOptionalKing(side) else {
            fatalError("Tried to access the \(side) king when it wasn't on the board [\(FEN)]")
        }
        return square
    }
    internal func findOptionalKing(_ side: Chess.Side) -> Chess.Square? {
        var kingSearch: Chess.Square?
        squares.forEach {
            if let piece = $0.piece, piece.side == side {
                switch piece.pieceType {
                case .king:
                    kingSearch = $0
                default:
                    break
                }
            }
        }
        return kingSearch
    }
    func prepareMove(_ move: inout Chess.Move) -> Chess.Move.Result? {
        let fromSquare = squares[move.start]
        let toSquare = squares[move.end]
        guard let piece = fromSquare.piece else {
            return .failed(reason: .noPieceToMove)
        }
        guard let toPiece = toSquare.piece else {
            // The square we are moving to is empty, check that it's a valid move.
            guard canPieceMove(&move, piece: piece) else {
                return .failed(reason: .invalidMoveForPiece)
            }
            return nil
        }
        guard piece.side != toPiece.side else {
            return .failed(reason: .sameSideAlreadyOccupiesDestination)
        }
        guard canPieceAttack(&move, piece: piece) else {
            return .failed(reason: .invalidAttackForPiece)
        }
        return nil
    }
    mutating func allSquaresAttacking(_ targetSquare: Chess.Square,
                                      side: Chess.Side,
                                      applyVariants: Bool) -> [Chess.Square] {
        var attackers: [Chess.Square] = []
        for square in squares {
            guard let piece = square.piece, piece.side == side else { continue }
            var attack = Chess.Move(side: side, start: square.position, end: targetSquare.position)
            var tmpBoard = Chess.Board(FEN: self.FEN)
            tmpBoard.playingSide = side
            let result = tmpBoard.attemptMove(&attack, applyVariants: applyVariants)
            switch result {
            case .success:
                attackers.append(square)
            default:
                break
            }
        }
        return attackers
    }
    // Returns false if move cannot be made
    mutating func attemptMove(_ move: inout Chess.Move, applyVariants: Bool = true) -> Chess.Move.Result {
        if let failedResult = prepareMove(&move) { return failedResult }
        // We need to attempt the move and see if it produces a board where the king is under attack.
        if applyVariants {
            let boardChange = Chess.BoardChange.moveMade(move: move)
            let testVariant = Chess.SingleMoveVariant(originalFEN: self.FEN,
                                                      changesToAttempt: [boardChange],
                                                      deepVariant: false)
            // Are we defending the king properly?
            if let kingSquare = testVariant.board.findOptionalKing(move.side) {
                let attackers = testVariant.board.allSquaresAttacking(kingSquare,
                                                                      side: move.side.opposingSide,
                                                                      applyVariants: false)
                if attackers.count>0 {
                    guard let loneAttacker = attackers.first else {
                        // Logic problem here
                        return .failed(reason: .unknown)
                    }
                    // There should be at least one, because `kingSquare.isUnderAttack`, but if
                    // there is more than one the move will not solve check
                    if attackers.count>1 {
                        return .failed(reason: .kingWouldBeUnderAttackAfterMove)
                    }
                    // There is only one attacker, but we are only a defender if this move takes out the attacker.
                    if loneAttacker.position.rank != move.end.rank || loneAttacker.position.file != move.end.file {
                        return .failed(reason: .kingWouldBeUnderAttackAfterMove)
                    }
                }
            }
        }

        // The move passed our tests, we can commit it safely
        move.setVerified()

        // Before we `commit` the move grab the destination square's piece,
        // if there is one, `commit` will over write it.
        // We do this with the special EnPassant capture as well.
        let capturedPiece: Chess.Piece?
        switch move.sideEffect {
        case .enPassantCapture(_, let trespasser):
            capturedPiece = squares[trespasser].piece
        default:
            capturedPiece = squares[move.end].piece
        }
        do {
            try commit(move, capturedPiece: capturedPiece)
        } catch let error {
            guard let limitation = error as? Chess.Move.Limitation else {
                return .failed(reason: .invalidMoveForPiece)
            }
            return .failed(reason: limitation)
        }
        return .success(capturedPiece: capturedPiece)
    }
    // swiftlint:disable function_body_length
    // Crashes if the move cannot be made, vet using attemptMove first.
    mutating func commit(_ move: Chess.Move, capturedPiece: Chess.Piece?) throws {
        guard let movingPiece = squares[move.start].piece else {
            throw Chess.Move.Limitation.noPieceToMove
        }
        guard movingPiece.side == playingSide else {
            throw Chess.Move.Limitation.notYourTurn
        }
        var unicodeString: String?
        var pgnString: String?
        var piece = movingPiece
        // When pawns move to their last rank, we need a promotion side effect
        // we default to queen promotion if none is given.
        if piece.isLastRank(move.end), move.sideEffect.isUnknown {
            move.sideEffect = .promotion(piece: .init(side: piece.side, pieceType: .queen(hasMoved: true)))
        }
        switch move.sideEffect {
        case .notKnown:
            throw move.sideEffect
        case .castling(let rookIndex, let destinationIndex):
            // We need to also move the rook
            guard let rook = squares[rookIndex].piece, rook.pieceType.isRook(),
                  rook.side == move.side, squares[destinationIndex].isEmpty else {
                throw move.sideEffect
            }
            unicodeString = (squares[rookIndex].isKingSide) ? "O-O" : "O-O-O"
            pgnString = unicodeString
            squares[rookIndex].clear()
            squares[destinationIndex].piece = rook
        case .promotion(let promotedPiece):
            // omg we're getting an upgrade.
            piece = promotedPiece
            let captureBase = (capturedPiece != nil) ? "\(move.start.file)x" : ""
            unicodeString = "\(captureBase)\(move.end.FEN)=\(promotedPiece.unicode)"
            pgnString = "\(captureBase)\(move.end.FEN)=\(promotedPiece.FEN)"
        case .enPassantInvade:
            break // This is handled by lastMove. We check that later to see if the invader double stepped.
        case .enPassantCapture: // This was handled before the commit, see capturedPiece.
            unicodeString = "\(move.start.file)x\(move.end)"
            pgnString = unicodeString
        case .noneish:
            break // Do nothing ish
        }
        squares[move.start].clear()
        squares[move.end].piece = piece
        if unicodeString == nil {
            switch movingPiece.pieceType {
            case .pawn:
                unicodeString = (capturedPiece != nil) ? "\(move.start.file)x\(move.end.FEN)" : "\(move.end.FEN)"
                pgnString = unicodeString
            case .knight, .bishop, .rook, .queen, .king:
                let unicodeCapture: String = (capturedPiece != nil) ? "x" : ""
                unicodeString = "\(piece.unicode)\(unicodeCapture)\(move.end.FEN)"
                pgnString = "\(piece.FEN)\(unicodeCapture)\(move.end.FEN)"
            }
        }
        move.unicodePGN = unicodeString
        move.PGN = pgnString
    }
    // swiftlint:enable function_body_length
    func canPieceAttack(_ move: inout Chess.Move, piece: Chess.Piece) -> Bool {
        // Attacks are moves, except when they aren't
        switch piece.pieceType {
        case .pawn:
            if move.rankDirection == piece.side.rankDirection,
                move.rankDistance == 1, move.fileDistance == 1 {
                // It's only a valid attack if a piece is present.
                guard !squares[move.end].isEmpty else {
                    return false
                }
                return true
            }
            return false
        default:
            return canPieceMove(&move, piece: piece)
        }
    }
    func canPieceMove(_ move: inout Chess.Move, piece: Chess.Piece) -> Bool {
        // Make sure it's a move
        if (move.rankDistance==0) && (move.fileDistance==0) {
            return false
        }
        switch piece.pieceType {
        case .pawn(let hasMoved):
            // Only forward
            if move.rankDirection == piece.side.rankDirection {
                if !squares[move.end].isEmpty {
                    // There is a piece at the destination, pawns only move to empty squares (this is not an attack)
                    return false
                }
                if move.rankDistance == 1, move.fileDistance == 0 { // Plain vanilla pawn move
                    return true
                }
                if move.rankDistance == 2, move.fileDistance == 0 {
                    // Two step is only allow as the first move
                    guard !hasMoved else { return false }
                    // Ensure the pawn isn't trying to jump a piece
                    let jumpPosition = (move.start + move.end) / 2
                    // If there is a piece in the spot one space forward, we can't move 2 spaces.
                    guard squares[jumpPosition].isEmpty else { return false }
                    // The move is valid. Before we return, make sure to attach the enPassantPosition
                    move.sideEffect = Chess.Move.SideEffect.enPassantInvade(territory: jumpPosition, invader: move.end)
                    return true
                }
                // Check the special case of EnPassant. The code would come through because the
                // destination square is empty. Which the system sees as a move, not an attack.
                if let enPassantPosition = enPassantPosition, move.end == enPassantPosition,
                   move.rankDistance == 1, move.fileDistance == 1 {
                    // We're capturing EnPassant, attach the SideEffect here.
                    let trespasser = move.start.adjacentPosition(rankOffset: 0, fileOffset: move.fileDirection)
                    move.sideEffect = Chess.Move.SideEffect.enPassantCapture(attack: move.end,
                                                                             trespasser: trespasser)
                    return true
                }
            }
            return false
        case .knight:
            return piece.isMoveValid(&move)
        case .bishop, .rook, .queen:
            guard piece.isMoveValid(&move) else { return false }
            return isMovePathOpen(move)
        case .king(let hasMoved):
            if move.rankDistance<2, move.fileDistance<2 {
                return true
            }
            // Are we trying to castle?
            if !hasMoved, move.rankDistance == 0, move.fileDistance == 2 {
                let isKingSide: Bool = move.fileDirection > 0
                let square = startingSquare(for: piece.side,
                                            pieceType: Chess.Piece.DefaultType.Rook,
                                            kingSide: isKingSide)
                if let rook = square.piece, case .rook(let hasMoved, _) = rook.pieceType, !hasMoved {
                    // Note "move.end - move.fileDirection" is always the square the king passes over when castling.
                    move.sideEffect = Chess.Move.SideEffect.castling(rook: square.position,
                                                                     destination: move.end - move.fileDirection)
                    return true
                }
            }
            return false
        }
    }
    private func isMovePathOpen(_ move: Chess.Move) -> Bool {
        let travel = move.rankDistance > move.fileDistance ? move.rankDistance : move.fileDistance
        guard travel>1 else {
            // We didn't travel far enough to be blocked
            return true
        }
        // Need to check steps between
        for tween in 1..<travel {
            let tweenPosition = Chess.Position.from(fileNumber: move.start.fileNumber + (tween * move.fileDirection),
                rank: move.start.rank + (tween * move.rankDirection))
            guard squares[tweenPosition].piece == nil else {
                return false
            }
        }
        return true
    }
}
