import 'package:campus_mobile/core/models/news_model.dart';
import 'package:campus_mobile/core/constants/app_constants.dart';
import 'package:flutter/material.dart';
import 'package:campus_mobile/core/services/news_service.dart';
import 'package:campus_mobile/ui/widgets/cards/card_container.dart';
import 'package:campus_mobile/ui/views/news/news_list.dart';

class NewsCard extends StatefulWidget {
  @override
  _NewsState createState() => _NewsState();
}

class _NewsState extends State<NewsCard> {
  final NewsService _newsService = NewsService();
  Future<NewsModel> _data;

  initState() {
    super.initState();
    _updateData();
  }

  _updateData() {
    if (!_newsService.isLoading) {
      setState(() {
        _data = _newsService.fetchData();
      });
    }
  }

  Widget buildNewsCard(AsyncSnapshot snapshot) {
    return NewsList(
      data: _data,
      listSize: 3,
    );
  }

  Widget buildTitle(String title) {
    return Text(
      title,
      textAlign: TextAlign.start,
    );
  }

  List<Widget> buildActionButtons() {
    List<Widget> actionButtons = List<Widget>();
    actionButtons.add(FlatButton(
      child: Text(
        'View All',
      ),
      onPressed: () {
        print('pushed onto navigations');
        Navigator.pushNamed(context, RoutePaths.NewsViewAll, arguments: _data);
      },
    ));
    return actionButtons;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<NewsModel>(
      future: _data,
      builder: (context, snapshot) {
        return CardContainer(
          /// TODO: need to hook up hidden to state using provider
          hidden: false,
          reload: () => _updateData(),
          isLoading: _newsService.isLoading,
          title: buildTitle("News"),
          errorText: _newsService.error,
          child: buildNewsCard(snapshot),
          actionButtons: buildActionButtons(),
        );
      },
    );
  }
}