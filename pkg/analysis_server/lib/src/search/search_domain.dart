// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/protocol/protocol_constants.dart';
import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/protocol_server.dart' as protocol;
import 'package:analysis_server/src/search/element_references.dart';
import 'package:analysis_server/src/search/type_hierarchy.dart';
import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/analysis/search.dart' as search;

/**
 * Instances of the class [SearchDomainHandler] implement a [RequestHandler]
 * that handles requests in the search domain.
 */
class SearchDomainHandler implements protocol.RequestHandler {
  /**
   * The analysis server that is using this handler to process requests.
   */
  final AnalysisServer server;

  /**
   * The [SearchEngine] for this server.
   */
  final SearchEngine searchEngine;

  /**
   * The next search response id.
   */
  int _nextSearchId = 0;

  /**
   * Initialize a newly created handler to handle requests for the given [server].
   */
  SearchDomainHandler(AnalysisServer server)
      : server = server,
        searchEngine = server.searchEngine;

  Future findElementReferences(protocol.Request request) async {
    var params =
        new protocol.SearchFindElementReferencesParams.fromRequest(request);
    String file = params.file;
    // prepare element
    Element element = await server.getElementAtOffset(file, params.offset);
    if (element is ImportElement) {
      element = (element as ImportElement).prefix;
    }
    if (element is FieldFormalParameterElement) {
      element = (element as FieldFormalParameterElement).field;
    }
    if (element is PropertyAccessorElement) {
      element = (element as PropertyAccessorElement).variable;
    }
    // respond
    String searchId = (_nextSearchId++).toString();
    var result = new protocol.SearchFindElementReferencesResult();
    if (element != null) {
      result.id = searchId;
      result.element = protocol.convertElement(element);
    }
    _sendSearchResult(request, result);
    // search elements
    if (element != null) {
      var computer = new ElementReferencesComputer(searchEngine);
      List<protocol.SearchResult> results =
          await computer.compute(element, params.includePotential);
      _sendSearchNotification(searchId, true, results);
    }
  }

  Future findMemberDeclarations(protocol.Request request) async {
    var params =
        new protocol.SearchFindMemberDeclarationsParams.fromRequest(request);
    await server.onAnalysisComplete;
    // respond
    String searchId = (_nextSearchId++).toString();
    _sendSearchResult(
        request, new protocol.SearchFindMemberDeclarationsResult(searchId));
    // search
    List<SearchMatch> matches =
        await searchEngine.searchMemberDeclarations(params.name);
    matches = SearchMatch.withNotNullElement(matches);
    _sendSearchNotification(searchId, true, matches.map(toResult));
  }

  Future findMemberReferences(protocol.Request request) async {
    var params =
        new protocol.SearchFindMemberReferencesParams.fromRequest(request);
    await server.onAnalysisComplete;
    // respond
    String searchId = (_nextSearchId++).toString();
    _sendSearchResult(
        request, new protocol.SearchFindMemberReferencesResult(searchId));
    // search
    List<SearchMatch> matches =
        await searchEngine.searchMemberReferences(params.name);
    matches = SearchMatch.withNotNullElement(matches);
    _sendSearchNotification(searchId, true, matches.map(toResult));
  }

  Future findTopLevelDeclarations(protocol.Request request) async {
    var params =
        new protocol.SearchFindTopLevelDeclarationsParams.fromRequest(request);
    try {
      // validate the regex
      new RegExp(params.pattern);
    } on FormatException catch (exception) {
      server.sendResponse(new protocol.Response.invalidParameter(
          request, 'pattern', exception.message));
      return;
    }

    await server.onAnalysisComplete;
    // respond
    String searchId = (_nextSearchId++).toString();
    _sendSearchResult(
        request, new protocol.SearchFindTopLevelDeclarationsResult(searchId));
    // search
    List<SearchMatch> matches =
        await searchEngine.searchTopLevelDeclarations(params.pattern);
    matches = SearchMatch.withNotNullElement(matches);
    _sendSearchNotification(searchId, true, matches.map(toResult));
  }

  /**
   * Implement the `search.getDeclarations` request.
   */
  Future getDeclarations(protocol.Request request) async {
    var params =
        new protocol.SearchGetElementDeclarationsParams.fromRequest(request);

    RegExp regExp;
    if (params.pattern != null) {
      try {
        regExp = new RegExp(params.pattern);
      } on FormatException catch (exception) {
        server.sendResponse(new protocol.Response.invalidParameter(
            request, 'pattern', exception.message));
        return;
      }
    }

    var files = <String>[];
    var declarations = <search.Declaration>[];

    protocol.ElementKind getElementKind(search.DeclarationKind kind) {
      switch (kind) {
        case search.DeclarationKind.CLASS:
          return protocol.ElementKind.CLASS;
        case search.DeclarationKind.CLASS_TYPE_ALIAS:
          return protocol.ElementKind.CLASS_TYPE_ALIAS;
        case search.DeclarationKind.CONSTRUCTOR:
          return protocol.ElementKind.CONSTRUCTOR;
        case search.DeclarationKind.ENUM:
          return protocol.ElementKind.ENUM;
        case search.DeclarationKind.ENUM_CONSTANT:
          return protocol.ElementKind.ENUM_CONSTANT;
        case search.DeclarationKind.FIELD:
          return protocol.ElementKind.FIELD;
        case search.DeclarationKind.FUNCTION:
          return protocol.ElementKind.FUNCTION;
        case search.DeclarationKind.FUNCTION_TYPE_ALIAS:
          return protocol.ElementKind.FUNCTION_TYPE_ALIAS;
        case search.DeclarationKind.GETTER:
          return protocol.ElementKind.GETTER;
        case search.DeclarationKind.METHOD:
          return protocol.ElementKind.METHOD;
        case search.DeclarationKind.SETTER:
          return protocol.ElementKind.SETTER;
        case search.DeclarationKind.VARIABLE:
          return protocol.ElementKind.TOP_LEVEL_VARIABLE;
        default:
          return protocol.ElementKind.CLASS;
      }
    }

    int remainingMaxResults = params.maxResults;
    for (var driver in server.driverMap.values.toList()) {
      var driverDeclarations =
          await driver.search.declarations(regExp, remainingMaxResults, files);
      declarations.addAll(driverDeclarations);

      if (remainingMaxResults != null) {
        remainingMaxResults -= driverDeclarations.length;
        if (remainingMaxResults <= 0) {
          break;
        }
      }
    }

    List<protocol.ElementDeclaration> elementDeclarations =
        declarations.map((declaration) {
      return new protocol.ElementDeclaration(
          declaration.name,
          getElementKind(declaration.kind),
          declaration.fileIndex,
          declaration.offset,
          declaration.line,
          declaration.column,
          declaration.codeOffset,
          declaration.codeLength,
          className: declaration.className,
          parameters: declaration.parameters);
    }).toList();

    server.sendResponse(new protocol.SearchGetElementDeclarationsResult(
            elementDeclarations, files)
        .toResponse(request.id));
  }

  /**
   * Implement the `search.getTypeHierarchy` request.
   */
  Future getTypeHierarchy(protocol.Request request) async {
    var params = new protocol.SearchGetTypeHierarchyParams.fromRequest(request);
    String file = params.file;
    // prepare element
    Element element = await server.getElementAtOffset(file, params.offset);
    if (element == null) {
      _sendTypeHierarchyNull(request);
      return;
    }
    // maybe supertype hierarchy only
    if (params.superOnly == true) {
      TypeHierarchyComputer computer =
          new TypeHierarchyComputer(searchEngine, element);
      List<protocol.TypeHierarchyItem> items = computer.computeSuper();
      protocol.Response response =
          new protocol.SearchGetTypeHierarchyResult(hierarchyItems: items)
              .toResponse(request.id);
      server.sendResponse(response);
      return;
    }
    // prepare type hierarchy
    TypeHierarchyComputer computer =
        new TypeHierarchyComputer(searchEngine, element);
    List<protocol.TypeHierarchyItem> items = await computer.compute();
    protocol.Response response =
        new protocol.SearchGetTypeHierarchyResult(hierarchyItems: items)
            .toResponse(request.id);
    server.sendResponse(response);
  }

  @override
  protocol.Response handleRequest(protocol.Request request) {
    try {
      String requestName = request.method;
      if (requestName == SEARCH_REQUEST_FIND_ELEMENT_REFERENCES) {
        findElementReferences(request);
        return protocol.Response.DELAYED_RESPONSE;
      } else if (requestName == SEARCH_REQUEST_FIND_MEMBER_DECLARATIONS) {
        findMemberDeclarations(request);
        return protocol.Response.DELAYED_RESPONSE;
      } else if (requestName == SEARCH_REQUEST_FIND_MEMBER_REFERENCES) {
        findMemberReferences(request);
        return protocol.Response.DELAYED_RESPONSE;
      } else if (requestName == SEARCH_REQUEST_FIND_TOP_LEVEL_DECLARATIONS) {
        findTopLevelDeclarations(request);
        return protocol.Response.DELAYED_RESPONSE;
      } else if (requestName == SEARCH_REQUEST_GET_ELEMENT_DECLARATIONS) {
        getDeclarations(request);
        return protocol.Response.DELAYED_RESPONSE;
      } else if (requestName == SEARCH_REQUEST_GET_TYPE_HIERARCHY) {
        getTypeHierarchy(request);
        return protocol.Response.DELAYED_RESPONSE;
      }
    } on protocol.RequestFailure catch (exception) {
      return exception.response;
    }
    return null;
  }

  void _sendSearchNotification(
      String searchId, bool isLast, Iterable<protocol.SearchResult> results) {
    server.sendNotification(
        new protocol.SearchResultsParams(searchId, results.toList(), isLast)
            .toNotification());
  }

  /**
   * Send a search response with the given [result] to the given [request].
   */
  void _sendSearchResult(protocol.Request request, result) {
    protocol.Response response = result.toResponse(request.id);
    server.sendResponse(response);
  }

  void _sendTypeHierarchyNull(protocol.Request request) {
    protocol.Response response =
        new protocol.SearchGetTypeHierarchyResult().toResponse(request.id);
    server.sendResponse(response);
  }

  static protocol.SearchResult toResult(SearchMatch match) {
    return protocol.newSearchResult_fromMatch(match);
  }
}
